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
    func run(sourceURL: URL, dryRun: Bool, nonInteractive: Bool = false) async throws -> Bool {
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
                let pluginName = pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry

                guard !blocklist.isBlocked(pluginName) else {
                    logger.debug("[\(pluginName)] skipped (blocklisted)")
                    continue
                }

                let ctx = HookContext(
                    pluginName: pluginName, hook: hook, temp: temp,
                    stateStore: stateStore, imageFiles: imageFiles,
                    dryRun: dryRun, nonInteractive: nonInteractive
                )
                let result = try await runPluginHook(ctx, ruleEvaluatorCache: &ruleEvaluatorCache)

                switch result {
                case .success, .warning, .skipped:
                    continue
                case .pluginNotFound, .secretMissing, .ruleCompilationFailed, .critical:
                    blocklist.block(pluginName)
                    return false
                }
            }
        }

        return true
    }

    // MARK: - Internal Types

    private struct HookContext {
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
        guard let loadedPlugin = try loadPlugin(named: ctx.pluginName) else {
            logger.error("Plugin '\(ctx.pluginName)' not found in \(pluginsDirectory.path)")
            return .pluginNotFound
        }

        // Fetch secrets
        let secrets: [String: String]
        do {
            secrets = try fetchSecrets(for: loadedPlugin)
        } catch {
            return .secretMissing
        }

        // Resolve execution log path
        let execLogPath = pluginsDirectory
            .appendingPathComponent(ctx.pluginName)
            .appendingPathComponent(PluginFile.executionLog)
        try FileManager.default.createDirectory(
            at: execLogPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let pluginConfigURL = pluginsDirectory
            .appendingPathComponent(ctx.pluginName)
            .appendingPathComponent(PluginFile.config)
        let pluginConfig = PluginConfig.load(fromIfExists: pluginConfigURL)

        // Evaluate declarative rules if present
        let manifestDeps = loadedPlugin.manifest.dependencyNames
        let rulesDidRun: Bool
        do {
            rulesDidRun = try await evaluateRules(
                ctx, manifestDeps: manifestDeps,
                pluginConfig: pluginConfig,
                ruleEvaluatorCache: &ruleEvaluatorCache
            )
        } catch {
            logger.error("[\(ctx.pluginName)] rule compilation failed: \(error.localizedDescription)")
            return .ruleCompilationFailed
        }

        // Skip binary execution if no command is configured
        let hookConfig = loadedPlugin.manifest.hooks[ctx.hook]
        guard hookConfig?.command != nil else {
            if rulesDidRun {
                logger.info("[\(ctx.pluginName)] hook '\(ctx.hook)': rules evaluated (no binary)")
            } else {
                logger.debug("[\(ctx.pluginName)] hook '\(ctx.hook)': no command and no rules — skipping")
            }
            return .skipped
        }

        // Build state and run binary
        return try await runBinary(
            ctx, loadedPlugin: loadedPlugin,
            secrets: secrets, pluginConfig: pluginConfig,
            hookConfig: hookConfig, manifestDeps: manifestDeps,
            rulesDidRun: rulesDidRun, execLogPath: execLogPath
        )
    }

    // MARK: - Rule Evaluation

    private func evaluateRules(
        _ ctx: HookContext,
        manifestDeps: [String],
        pluginConfig: PluginConfig,
        ruleEvaluatorCache: inout [String: RuleEvaluator]
    ) async throws -> Bool {
        guard !pluginConfig.rules.isEmpty else { return false }

        let evaluator: RuleEvaluator
        if let cached = ruleEvaluatorCache[ctx.pluginName] {
            evaluator = cached
        } else {
            evaluator = try RuleEvaluator(
                rules: pluginConfig.rules,
                nonInteractive: ctx.nonInteractive,
                logger: logger
            )
            ruleEvaluatorCache[ctx.pluginName] = evaluator
        }

        let imageURLs = Dictionary(uniqueKeysWithValues: ctx.imageFiles.map {
            ($0.lastPathComponent, $0)
        })
        let buffer = MetadataBuffer(imageURLs: imageURLs)

        var didRun = false
        for imageName in await ctx.stateStore.allImageNames {
            let resolved = await ctx.stateStore.resolve(
                image: imageName, dependencies: manifestDeps + [ReservedName.original, ctx.pluginName]
            )
            let currentNamespace = resolved[ctx.pluginName] ?? [:]
            let ruleOutput = await evaluator.evaluate(
                hook: ctx.hook, state: resolved, currentNamespace: currentNamespace,
                metadataBuffer: buffer, imageName: imageName
            )
            if ruleOutput != currentNamespace {
                await ctx.stateStore.setNamespace(
                    image: imageName, plugin: ctx.pluginName, values: ruleOutput
                )
                didRun = true
            }
        }

        await buffer.flush()
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

        // Build state payload for JSON protocol plugins with dependencies
        let proto: PluginProtocol = hookConfig?.pluginProtocol ?? .json
        let pluginState = await buildStatePayload(
            proto: proto, manifestDeps: manifestDeps,
            pluginName: ctx.pluginName, rulesDidRun: rulesDidRun,
            stateStore: ctx.stateStore
        )

        logger.info("Running plugin '\(ctx.pluginName)' for hook '\(ctx.hook)'")
        let (result, returnedState) = try await runner.run(
            hook: ctx.hook,
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
                        image: imageName, plugin: ctx.pluginName, values: values
                    )
                } else {
                    await ctx.stateStore.setNamespace(
                        image: imageName, plugin: ctx.pluginName, values: values
                    )
                }
            }
        }

        switch result {
        case .success:
            logger.info("[\(ctx.pluginName)] hook '\(ctx.hook)': success")
            return .success
        case .warning:
            logger.warning("[\(ctx.pluginName)] hook '\(ctx.hook)': completed with warnings")
            return .warning
        case .critical:
            logger.error(
                "[\(ctx.pluginName)] hook '\(ctx.hook)': critical failure — aborting pipeline"
            )
            return .critical
        }
    }

    // MARK: - State Payload

    private func buildStatePayload(
        proto: PluginProtocol,
        manifestDeps: [String],
        pluginName: String,
        rulesDidRun: Bool,
        stateStore: StateStore
    ) async -> [String: [String: [String: JSONValue]]]? {
        guard proto == .json, !manifestDeps.isEmpty || rulesDidRun else { return nil }

        var statePayload: [String: [String: [String: JSONValue]]] = [:]
        let allDeps = rulesDidRun ? manifestDeps + [pluginName] : manifestDeps
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
            for pluginName in pipeline[hook] ?? [] {
                let name = pluginName.split(separator: ":").first.map(String.init) ?? pluginName
                if let loaded = try loadPlugin(named: name) {
                    if !allManifests.contains(where: { $0.name == loaded.manifest.name }) {
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

    private func loadPlugin(named name: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(name)
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        return LoadedPlugin(name: name, directory: pluginDir, manifest: manifest)
    }

    /// Fetches all declared secrets for a plugin from the secret store.
    private func fetchSecrets(for plugin: LoadedPlugin) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secretKeys {
            do {
                let value = try secretStore.getPluginSecret(plugin: plugin.name, key: key)
                result[key] = value
            } catch {
                logger.error(
                    "[\(plugin.name)] required secret '\(key)' not found: \(error)"
                )
                logger.error("Run 'piqley secret set \(plugin.name) \(key)' to configure it.")
                throw SecretStoreError.notFound(key: SecretNamespace.pluginKey(plugin: plugin.name, key: key))
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
