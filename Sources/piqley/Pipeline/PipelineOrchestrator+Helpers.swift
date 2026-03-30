import Foundation
import Logging
import PiqleyCore

extension PipelineOrchestrator {
    // MARK: - State Payload

    func buildStatePayload(
        proto: PluginProtocol,
        hasEnvironmentMapping: Bool = false,
        manifestDeps: [String],
        pluginIdentifier: String,
        rulesDidRun: Bool,
        stateStore: StateStore,
        skippedImages: Set<String> = []
    ) async -> [String: [String: [String: JSONValue]]]? {
        let needsState = hasEnvironmentMapping || (proto == .json && (!manifestDeps.isEmpty || rulesDidRun))
        guard needsState else { return nil }

        var statePayload: [String: [String: [String: JSONValue]]] = [:]
        let allDeps = rulesDidRun
            ? manifestDeps + [ReservedName.original, pluginIdentifier, ReservedName.skip]
            : manifestDeps + [ReservedName.original, ReservedName.skip]
        for imageName in await stateStore.allImageNames {
            if skippedImages.contains(imageName) { continue }
            let resolved = await stateStore.resolve(
                image: imageName, dependencies: allDeps
            )
            if !resolved.isEmpty {
                statePayload[imageName] = resolved
            }
        }
        return statePayload.isEmpty ? nil : statePayload
    }

    // MARK: - Dependency Validation

    func validateDependencies(pipeline: [String: [String]]) throws {
        var allManifests: [PluginManifest] = []
        for hook in registry.executionOrder {
            for pluginEntry in pipeline[hook] ?? [] {
                let identifier = pluginEntry
                if let loaded = try loadPlugin(named: identifier) {
                    if !allManifests.contains(where: { $0.identifier == loaded.manifest.identifier }) {
                        allManifests.append(loaded.manifest)
                    }
                }
            }
        }
        if let error = DependencyValidator.validate(manifests: allManifests, pipeline: pipeline, stageOrder: registry.executionOrder) {
            logger.error("Dependency validation failed: \(error)")
            throw PipelineError.dependencyValidationFailed(error)
        }
    }

    func loadPlugin(named identifier: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(identifier)
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: data)

        // Load stages from workflow rules dir instead of plugin dir
        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: workflow.name, pluginIdentifier: identifier, root: workflowsRoot
        )
        let knownHooks = registry.allKnownNames
        let (stages, _) = PluginDiscovery.loadStages(from: rulesDir, knownHooks: knownHooks, logger: logger)

        return LoadedPlugin(
            identifier: manifest.identifier, name: manifest.name,
            directory: pluginDir, manifest: manifest, stages: stages
        )
    }

    // MARK: - Binary Validation

    func validateBinaries(pipeline: [String: [String]]) throws {
        for hook in registry.executionOrder {
            for pluginEntry in pipeline[hook] ?? [] {
                guard let loadedPlugin = try loadPlugin(named: pluginEntry) else { continue }
                guard let stageConfig = loadedPlugin.stages[hook] else { continue }
                guard let binary = stageConfig.binary,
                      let command = binary.command,
                      !command.isEmpty else { continue }

                let probeResult = BinaryProbe.probe(
                    command: command, pluginDirectory: loadedPlugin.directory
                )

                switch probeResult {
                case .notFound:
                    let resolved = BinaryProbe.resolveExecutable(command, pluginDirectory: loadedPlugin.directory)
                    logger.error("Binary not found for plugin '\(pluginEntry)': \(resolved)")
                    throw PipelineError.binaryValidationFailed(pluginEntry)
                case .notExecutable:
                    let resolved = BinaryProbe.resolveExecutable(command, pluginDirectory: loadedPlugin.directory)
                    logger.error("Binary not executable for plugin '\(pluginEntry)': \(resolved)")
                    throw PipelineError.binaryValidationFailed(pluginEntry)
                case .piqleyPlugin:
                    let configuredProto = binary.pluginProtocol ?? .json
                    if configuredProto != .json {
                        let msg = "Protocol mismatch for plugin '\(pluginEntry)': "
                            + "binary is a piqley plugin but protocol is configured as '\(configuredProto.rawValue)'"
                        logger.error("\(msg)")
                        throw PipelineError.binaryValidationFailed(pluginEntry)
                    }
                case .cliTool:
                    let configuredProto = binary.pluginProtocol ?? .json
                    if configuredProto == .json {
                        logger.error("Protocol mismatch for plugin '\(pluginEntry)': binary is a CLI tool but protocol is configured as 'json'")
                        throw PipelineError.binaryValidationFailed(pluginEntry)
                    }
                }
            }
        }
    }

    // MARK: - Config and Secret Resolution

    enum ConfigResolutionResult {
        case resolved(secrets: [String: String], config: PluginConfig)
        case secretMissing
    }

    func resolvePluginConfigAndSecrets(
        plugin: LoadedPlugin, pluginIdentifier: String
    ) -> ConfigResolutionResult {
        let configStore = BasePluginConfigStore.default
        let baseConfig = (try? configStore.load(for: pluginIdentifier)) ?? BasePluginConfig()
        let workflowOverrides = workflow.config[pluginIdentifier]

        // Verify all manifest-declared secrets have aliases in the config
        let merged = workflowOverrides.map { baseConfig.merging($0) } ?? baseConfig
        for key in plugin.manifest.secretKeys where merged.secrets[key] == nil {
            // No alias configured: fall back to legacy lookup for unmigrated plugins.
            guard (try? secretStore.getPluginSecret(plugin: pluginIdentifier, key: key)) != nil else {
                logger.error("[\(plugin.name)] required secret '\(key)' not found")
                logger.error("Run 'piqley secret set \(pluginIdentifier) \(key)' or 'piqley setup' to configure it.")
                return .secretMissing
            }
        }

        do {
            let resolved = try ConfigResolver.resolve(
                base: baseConfig,
                workflowOverrides: workflowOverrides,
                secretStore: secretStore
            )
            return .resolved(secrets: resolved.secrets, config: PluginConfig(values: resolved.values))
        } catch {
            // Fall back to legacy secret fetching for unmigrated plugins
            guard let legacySecrets = try? fetchSecrets(for: plugin) else {
                return .secretMissing
            }
            return .resolved(secrets: legacySecrets, config: PluginConfig(values: baseConfig.values))
        }
    }

    /// Fetches all declared secrets for a plugin from the secret store (legacy format).
    func fetchSecrets(for plugin: LoadedPlugin) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secretKeys {
            do {
                let value = try secretStore.getPluginSecret(plugin: plugin.identifier, key: key)
                result[key] = value
            } catch {
                logger.error("[\(plugin.name)] required secret '\(key)' not found: \(error)")
                logger.error("Run 'piqley secret set \(plugin.identifier) \(key)' to configure it.")
                throw SecretStoreError.notFound(
                    key: SecretNamespace.pluginKey(plugin: plugin.identifier, key: key)
                )
            }
        }
        return result
    }

    // MARK: - Rule Evaluation

    // swiftlint:disable:next function_parameter_count
    func evaluateRuleset(
        rules: [Rule],
        ctx: HookContext,
        manifestDeps: [String],
        buffer: MetadataBuffer,
        ruleEvaluatorCache: inout [String: RuleEvaluator],
        cacheKey: String,
        skippedImages: Set<String> = []
    ) async throws -> RulesetResult {
        let evaluator: RuleEvaluator
        if let cached = ruleEvaluatorCache[cacheKey] {
            evaluator = cached
        } else {
            evaluator = try RuleEvaluator(
                rules: rules,
                pluginId: ctx.pluginIdentifier,
                nonInteractive: ctx.nonInteractive,
                logger: logger
            )
            ruleEvaluatorCache[cacheKey] = evaluator
        }

        var didRun = false
        var currentSkipped = skippedImages
        let ruleDeps = Array(evaluator.referencedNamespaces)
        for imageName in await ctx.stateStore.allImageNames {
            if currentSkipped.contains(imageName) { continue }

            let resolved = await ctx.stateStore.resolve(
                image: imageName,
                dependencies: manifestDeps + ruleDeps + [ReservedName.original, ctx.pluginIdentifier, ReservedName.skip]
            )
            let currentNamespace = resolved[ctx.pluginIdentifier] ?? [:]
            let ruleResult = await evaluator.evaluate(
                state: resolved, currentNamespace: currentNamespace,
                metadataBuffer: buffer, imageName: imageName,
                pluginId: ctx.pluginIdentifier, stateStore: ctx.stateStore
            )

            if ruleResult.skipped {
                currentSkipped.insert(imageName)
                didRun = true
                continue
            }

            let ruleOutput = ruleResult.namespace
            if ruleOutput != currentNamespace {
                await ctx.stateStore.setNamespace(
                    image: imageName, plugin: ctx.pluginIdentifier, values: ruleOutput
                )
                didRun = true
            }
        }

        return RulesetResult(didRun: didRun, skippedImages: currentSkipped)
    }

    // MARK: - Skip Records

    func buildSkipRecords(skippedImages: Set<String>, stateStore: StateStore) async -> [SkipRecord] {
        var skipRecords: [SkipRecord] = []
        for imageName in skippedImages {
            let resolved = await stateStore.resolve(
                image: imageName, dependencies: [ReservedName.skip]
            )
            if case let .array(records) = resolved[ReservedName.skip]?[ReservedName.skipRecords] {
                for record in records {
                    if case let .object(dict) = record,
                       case let .string(file) = dict["file"],
                       case let .string(plugin) = dict["plugin"]
                    {
                        skipRecords.append(SkipRecord(file: file, plugin: plugin))
                    }
                }
            }
        }
        return skipRecords
    }

    // MARK: - Binary Execution

    // swiftlint:disable:next function_parameter_count
    func runBinary(
        _ ctx: HookContext,
        loadedPlugin: LoadedPlugin,
        secrets: [String: String],
        pluginConfig: PluginConfig,
        hookConfig: HookConfig?,
        manifestDeps: [String],
        rulesDidRun: Bool,
        execLogPath: URL,
        skipped: [SkipRecord] = [],
        skippedImages: Set<String> = [],
        metadataBuffer: MetadataBuffer? = nil,
        pipelineRunId: String? = nil
    ) async throws -> (HookResult, [String]) {
        let runner = PluginRunner(
            plugin: loadedPlugin, secrets: secrets, pluginConfig: pluginConfig,
            metadataBuffer: metadataBuffer
        )

        // Build state payload for plugins that need it:
        // - JSON protocol plugins with dependencies (state goes on stdin)
        // - Any plugin with environment mappings (templates resolve against state)
        let proto: PluginProtocol = hookConfig?.pluginProtocol ?? .json
        let hasEnvironmentMapping = hookConfig?.environment != nil
        let pluginState = await buildStatePayload(
            proto: proto, hasEnvironmentMapping: hasEnvironmentMapping,
            manifestDeps: manifestDeps,
            pluginIdentifier: ctx.pluginIdentifier, rulesDidRun: rulesDidRun,
            stateStore: ctx.stateStore,
            skippedImages: skippedImages
        )

        let output = try await runner.run(
            hook: ctx.hook,
            hookConfig: hookConfig,
            tempFolder: ctx.temp,
            executionLogPath: execLogPath,
            dryRun: ctx.dryRun,
            debug: ctx.debug,
            state: pluginState,
            skipped: skipped,
            pipelineRunId: pipelineRunId
        )
        let result = output.exitResult
        let returnedState = output.state

        // Create skip records for images the plugin skipped at runtime
        for filename in output.skippedImages {
            let record = JSONValue.object(["file": .string(filename), "plugin": .string(ctx.pluginIdentifier)])
            await ctx.stateStore.appendSkipRecord(image: filename, record: record)
        }

        // Store returned state under the plugin's namespace
        if let returnedState {
            let checkURL = ctx.temp.url
            for (imageName, values) in returnedState {
                let imageExists = FileManager.default.fileExists(
                    atPath: checkURL.appendingPathComponent(imageName).path
                )
                guard imageExists else { continue }
                if rulesDidRun {
                    await ctx.stateStore.mergeNamespace(
                        image: imageName, plugin: ctx.pluginIdentifier, values: values
                    )
                } else {
                    await ctx.stateStore.setNamespace(
                        image: imageName, plugin: ctx.pluginIdentifier, values: values
                    )
                }
            }
        }

        if let errorMessage = output.errorMessage {
            logger.error("[\(loadedPlugin.name)] error: \(errorMessage)")
        }

        switch result {
        case .success:
            logger.info("[\(loadedPlugin.name)] stage '\(ctx.stage)': success")
            return (.success, output.skippedImages)
        case .warning:
            logger.warning("[\(loadedPlugin.name)] stage '\(ctx.stage)': completed with warnings")
            return (.warning, output.skippedImages)
        case .critical:
            logger.error(
                "[\(loadedPlugin.name)] stage '\(ctx.stage)': critical failure — aborting pipeline"
            )
            return (.critical, output.skippedImages)
        }
    }
}

// MARK: - Pipeline Errors

enum PipelineError: Error, LocalizedError {
    case dependencyValidationFailed(String)
    case binaryValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .dependencyValidationFailed(msg):
            "Dependency validation failed: \(msg)"
        case let .binaryValidationFailed(plugin):
            "Binary validation failed for plugin: \(plugin)"
        }
    }
}
