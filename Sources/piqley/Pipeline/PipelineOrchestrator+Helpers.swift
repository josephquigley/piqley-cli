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
        stateStore: StateStore
    ) async -> [String: [String: [String: JSONValue]]]? {
        let needsState = (proto == .json || hasEnvironmentMapping) && (!manifestDeps.isEmpty || rulesDidRun)
        guard needsState else { return nil }

        var statePayload: [String: [String: [String: JSONValue]]] = [:]
        let allDeps = rulesDidRun
            ? manifestDeps + [pluginIdentifier, ReservedName.skip]
            : manifestDeps + [ReservedName.skip]
        for imageName in await stateStore.allImageNames {
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
        for hook in Hook.canonicalOrder.map(\.rawValue) {
            for pluginEntry in pipeline[hook] ?? [] {
                let identifier = pluginEntry
                if let loaded = try loadPlugin(named: identifier) {
                    if !allManifests.contains(where: { $0.identifier == loaded.manifest.identifier }) {
                        allManifests.append(loaded.manifest)
                    }
                }
            }
        }
        if let error = DependencyValidator.validate(manifests: allManifests, pipeline: pipeline) {
            logger.error("Dependency validation failed: \(error)")
            throw PipelineError.dependencyValidationFailed(error)
        }
    }

    func loadPlugin(named identifier: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(identifier)
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
        let stages = PluginDiscovery.loadStages(from: pluginDir, knownHooks: knownHooks, logger: logger)

        return LoadedPlugin(
            identifier: manifest.identifier, name: manifest.name,
            directory: pluginDir, manifest: manifest, stages: stages
        )
    }

    // MARK: - Binary Validation

    func validateBinaries(pipeline: [String: [String]]) throws {
        for hook in Hook.canonicalOrder.map(\.rawValue) {
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

    /// Fetches all declared secrets for a plugin from the secret store.
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
                nonInteractive: ctx.nonInteractive,
                logger: logger
            )
            ruleEvaluatorCache[cacheKey] = evaluator
        }

        var didRun = false
        var currentSkipped = skippedImages
        for imageName in await ctx.stateStore.allImageNames {
            if currentSkipped.contains(imageName) { continue }

            let resolved = await ctx.stateStore.resolve(
                image: imageName,
                dependencies: manifestDeps + [ReservedName.original, ctx.pluginIdentifier, ReservedName.skip]
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
        imageFolderURL: URL? = nil
    ) async throws -> HookResult {
        let runner = PluginRunner(
            plugin: loadedPlugin, secrets: secrets, pluginConfig: pluginConfig
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
            stateStore: ctx.stateStore
        )

        logger.info("Running plugin '\(loadedPlugin.name)' for hook '\(ctx.hook)'")
        let (result, returnedState) = try await runner.run(
            hook: ctx.hook,
            hookConfig: hookConfig,
            tempFolder: ctx.temp,
            executionLogPath: execLogPath,
            dryRun: ctx.dryRun,
            state: pluginState,
            skipped: skipped,
            imageFolderOverride: imageFolderURL
        )

        // Store returned state under the plugin's namespace
        if let returnedState {
            let checkURL = imageFolderURL ?? ctx.temp.url
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

        switch result {
        case .success:
            logger.info("[\(loadedPlugin.name)] hook '\(ctx.hook)': success")
            return .success
        case .warning:
            logger.warning("[\(loadedPlugin.name)] hook '\(ctx.hook)': completed with warnings")
            return .warning
        case .critical:
            logger.error(
                "[\(loadedPlugin.name)] hook '\(ctx.hook)': critical failure — aborting pipeline"
            )
            return .critical
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
