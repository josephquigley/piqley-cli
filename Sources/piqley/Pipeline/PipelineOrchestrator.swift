import Foundation
import Logging
import PiqleyCore

struct PipelineOrchestrator: Sendable {
    let config: AppConfig
    let pluginsDirectory: URL
    let secretStore: any SecretStore
    private let logger = Logger(label: "piqley.pipeline")

    /// Resolves the default plugins directory.
    static var defaultPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.plugins)
    }

    /// Runs the full pipeline for a source folder.
    /// Returns `true` if all hooks succeeded, `false` if any hook aborted the pipeline.
    func run(sourceURL: URL, dryRun: Bool, nonInteractive: Bool = false, overwriteSource: Bool = false) async throws -> Bool {
        var pipeline = config.pipeline

        // Auto-discover new plugins if enabled
        if config.autoDiscoverPlugins {
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDirectory)
            let discovered = try discovery.loadManifests(disabled: config.disabledPlugins)
            PluginDiscovery.autoAppend(discovered: discovered, into: &pipeline)
        }

        // Create temp folder and copy images
        let temp = try TempFolder.create()
        logger.info("Temp folder: \(temp.url.path)")
        do {
            try temp.copyImages(from: sourceURL)
        } catch {
            try? temp.delete()
            throw error
        }

        let blocklist = PluginBlocklist()
        let stateStore = StateStore()
        var ruleEvaluatorCache: [String: RuleEvaluator] = [:]

        // Extract metadata from all images into original namespace
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: temp.url, includingPropertiesForKeys: nil
        ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

        for imageFile in imageFiles {
            let metadata = MetadataExtractor.extract(from: imageFile)
            await stateStore.setNamespace(
                image: imageFile.lastPathComponent,
                plugin: ReservedName.original,
                values: metadata
            )
        }

        // Validate plugin dependencies
        do {
            try validateDependencies(pipeline: pipeline)
        } catch is PipelineError {
            try? temp.delete()
            return false
        }

        defer {
            do {
                try temp.delete()
                logger.debug("Temp folder deleted")
            } catch {
                logger.warning("Failed to delete temp folder: \(error)")
            }
        }

        // Execute hooks in order
        for hook in Hook.canonicalOrder.map(\.rawValue) {
            for pluginEntry in pipeline[hook] ?? [] {
                let pluginIdentifier = pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry

                guard !blocklist.isBlocked(pluginIdentifier) else {
                    logger.debug("[\(pluginIdentifier)] skipped (blocklisted)")
                    continue
                }

                let ctx = HookContext(
                    pluginIdentifier: pluginIdentifier, pluginName: pluginIdentifier,
                    hook: hook, temp: temp,
                    stateStore: stateStore, imageFiles: imageFiles,
                    dryRun: dryRun, nonInteractive: nonInteractive
                )
                let result = try await runPluginHook(ctx, ruleEvaluatorCache: &ruleEvaluatorCache)

                switch result {
                case .success, .warning, .skipped:
                    continue
                case .pluginNotFound, .secretMissing, .ruleCompilationFailed, .critical:
                    blocklist.block(pluginIdentifier)
                    return false
                }
            }
        }

        // Copy processed images back to source if requested
        if overwriteSource {
            try temp.copyBack(to: sourceURL)
            logger.info("Copied processed images back to \(sourceURL.path)")
        }

        return true
    }

    // MARK: - Internal Types

    private struct HookContext {
        let pluginIdentifier: String
        let pluginName: String
        let hook: String
        let temp: TempFolder
        let stateStore: StateStore
        let imageFiles: [URL]
        let dryRun: Bool
        let nonInteractive: Bool
    }

    private enum HookResult {
        case success, warning, critical, skipped
        case pluginNotFound, secretMissing, ruleCompilationFailed
    }

    // MARK: - Per-Plugin Hook Execution

    private func runPluginHook(
        _ ctx: HookContext,
        ruleEvaluatorCache: inout [String: RuleEvaluator]
    ) async throws -> HookResult {
        guard let loadedPlugin = try loadPlugin(named: ctx.pluginIdentifier) else {
            logger.error("Plugin '\(ctx.pluginIdentifier)' not found in \(pluginsDirectory.path)")
            return .pluginNotFound
        }

        guard let stageConfig = loadedPlugin.stages[ctx.hook] else {
            logger.debug("[\(loadedPlugin.name)] hook '\(ctx.hook)': no stage file — skipping")
            return .skipped
        }

        let secrets: [String: String]
        do {
            secrets = try fetchSecrets(for: loadedPlugin)
        } catch {
            return .secretMissing
        }

        let execLogPath = pluginsDirectory
            .appendingPathComponent(ctx.pluginIdentifier)
            .appendingPathComponent(PluginFile.executionLog)
        try FileManager.default.createDirectory(
            at: execLogPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let pluginConfigURL = pluginsDirectory
            .appendingPathComponent(ctx.pluginIdentifier)
            .appendingPathComponent(PluginFile.config)
        let pluginConfig = PluginConfig.load(fromIfExists: pluginConfigURL)
        let manifestDeps = loadedPlugin.manifest.dependencyIdentifiers

        let imageURLs = Dictionary(uniqueKeysWithValues: ctx.imageFiles.map {
            ($0.lastPathComponent, $0)
        })
        let buffer = MetadataBuffer(imageURLs: imageURLs)

        // Pre-rules
        var preRulesDidRun = false
        if let preRules = stageConfig.preRules, !preRules.isEmpty {
            do {
                preRulesDidRun = try await evaluateRuleset(
                    rules: preRules, ctx: ctx, manifestDeps: manifestDeps,
                    buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
                    cacheKey: "\(ctx.pluginIdentifier):pre:\(ctx.hook)"
                )
            } catch {
                logger.error("[\(loadedPlugin.name)] pre-rule compilation failed: \(error.localizedDescription)")
                return .ruleCompilationFailed
            }
        }

        await buffer.flush()

        // Binary
        var binaryDidRun = false
        if stageConfig.binary?.command != nil {
            let result = try await runBinary(
                ctx, loadedPlugin: loadedPlugin,
                secrets: secrets, pluginConfig: pluginConfig,
                hookConfig: stageConfig.binary, manifestDeps: manifestDeps,
                rulesDidRun: preRulesDidRun, execLogPath: execLogPath
            )
            switch result {
            case .success, .warning:
                binaryDidRun = true
            case .critical, .pluginNotFound, .secretMissing, .ruleCompilationFailed:
                return result
            case .skipped:
                break
            }
        }

        // Invalidate cache after binary
        if binaryDidRun {
            await buffer.invalidateAll()
        }

        // Post-rules
        if let postRules = stageConfig.postRules, !postRules.isEmpty {
            do {
                _ = try await evaluateRuleset(
                    rules: postRules, ctx: ctx, manifestDeps: manifestDeps,
                    buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
                    cacheKey: "\(ctx.pluginIdentifier):post:\(ctx.hook)"
                )
            } catch {
                logger.error("[\(loadedPlugin.name)] post-rule compilation failed: \(error.localizedDescription)")
                return .ruleCompilationFailed
            }
        }

        await buffer.flush()

        if !preRulesDidRun, !binaryDidRun, (stageConfig.postRules ?? []).isEmpty {
            return .skipped
        }
        return .success
    }

    // MARK: - Rule Evaluation

    // swiftlint:disable:next function_parameter_count
    private func evaluateRuleset(
        rules: [Rule],
        ctx: HookContext,
        manifestDeps: [String],
        buffer: MetadataBuffer,
        ruleEvaluatorCache: inout [String: RuleEvaluator],
        cacheKey: String
    ) async throws -> Bool {
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
        for imageName in await ctx.stateStore.allImageNames {
            let resolved = await ctx.stateStore.resolve(
                image: imageName, dependencies: manifestDeps + [ReservedName.original, ctx.pluginIdentifier]
            )
            let currentNamespace = resolved[ctx.pluginIdentifier] ?? [:]
            let ruleResult = await evaluator.evaluate(
                state: resolved, currentNamespace: currentNamespace,
                metadataBuffer: buffer, imageName: imageName
            )
            let ruleOutput = ruleResult.namespace
            if ruleOutput != currentNamespace {
                await ctx.stateStore.setNamespace(
                    image: imageName, plugin: ctx.pluginIdentifier, values: ruleOutput
                )
                didRun = true
            }
        }

        return didRun
    }

    // MARK: - Binary Execution

    // swiftlint:disable:next function_parameter_count
    private func runBinary(
        _ ctx: HookContext,
        loadedPlugin: LoadedPlugin,
        secrets: [String: String],
        pluginConfig: PluginConfig,
        hookConfig: HookConfig?,
        manifestDeps: [String],
        rulesDidRun: Bool,
        execLogPath: URL
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
            state: pluginState
        )

        // Store returned state under the plugin's namespace
        if let returnedState {
            for (imageName, values) in returnedState {
                let imageExists = FileManager.default.fileExists(
                    atPath: ctx.temp.url.appendingPathComponent(imageName).path
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

    // MARK: - State Payload

    private func buildStatePayload(
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
        let allDeps = rulesDidRun ? manifestDeps + [pluginIdentifier] : manifestDeps
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

    private func validateDependencies(pipeline: [String: [String]]) throws {
        var allManifests: [PluginManifest] = []
        for hook in Hook.canonicalOrder.map(\.rawValue) {
            for pluginEntry in pipeline[hook] ?? [] {
                let identifier = pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry
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

    private func loadPlugin(named identifier: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(identifier)
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
        let stages = PluginDiscovery.loadStages(from: pluginDir, knownHooks: knownHooks, logger: logger)

        return LoadedPlugin(identifier: manifest.identifier, name: manifest.name, directory: pluginDir, manifest: manifest, stages: stages)
    }

    /// Fetches all declared secrets for a plugin from the secret store.
    private func fetchSecrets(for plugin: LoadedPlugin) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secretKeys {
            do {
                let value = try secretStore.getPluginSecret(plugin: plugin.identifier, key: key)
                result[key] = value
            } catch {
                logger.error("[\(plugin.name)] required secret '\(key)' not found: \(error)")
                logger.error("Run 'piqley secret set \(plugin.identifier) \(key)' to configure it.")
                throw SecretStoreError.notFound(key: SecretNamespace.pluginKey(plugin: plugin.identifier, key: key))
            }
        }
        return result
    }
}

// MARK: - Pipeline Errors

enum PipelineError: Error, LocalizedError {
    case dependencyValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .dependencyValidationFailed(msg):
            "Dependency validation failed: \(msg)"
        }
    }
}
