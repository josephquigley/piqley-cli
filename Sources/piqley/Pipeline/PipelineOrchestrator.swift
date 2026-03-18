import Foundation
import Logging

struct PipelineOrchestrator: Sendable {
    let config: AppConfig
    let pluginsDirectory: URL
    let secretStore: any SecretStore
    private let logger = Logger(label: "piqley.pipeline")

    /// Resolves the default plugins directory.
    static var defaultPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/plugins")
    }

    /// Runs the full pipeline for a source folder.
    /// Returns `true` if all hooks succeeded, `false` if any hook aborted the pipeline.
    func run(sourceURL: URL, dryRun: Bool) async throws -> Bool {
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

        // Extract metadata from all images into original namespace
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: temp.url, includingPropertiesForKeys: nil
        ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

        for imageFile in imageFiles {
            let metadata = MetadataExtractor.extract(from: imageFile)
            await stateStore.setNamespace(
                image: imageFile.lastPathComponent,
                plugin: "original",
                values: metadata
            )
        }

        // Validate plugin dependencies
        var allManifests: [PluginManifest] = []
        for hook in PluginManifest.canonicalHooks {
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
        for hook in PluginManifest.canonicalHooks {
            let pluginNames = pipeline[hook] ?? []
            for pluginEntry in pluginNames {
                // Strip any suffix (e.g. ":required" kept for forward-compat)
                let pluginName = pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry

                guard !blocklist.isBlocked(pluginName) else {
                    logger.debug("[\(pluginName)] skipped (blocklisted)")
                    continue
                }

                guard let loadedPlugin = try loadPlugin(named: pluginName) else {
                    logger.error("Plugin '\(pluginName)' not found in \(pluginsDirectory.path)")
                    blocklist.block(pluginName)
                    return false
                }

                // Fetch secrets — missing secret is a critical failure
                let secrets: [String: String]
                do {
                    secrets = try fetchSecrets(for: loadedPlugin)
                } catch {
                    blocklist.block(pluginName)
                    return false
                }

                // Resolve execution log path (tilde-expanded)
                let execLogPath = pluginsDirectory
                    .appendingPathComponent(pluginName)
                    .appendingPathComponent("logs/execution.jsonl")
                try FileManager.default.createDirectory(
                    at: execLogPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let pluginConfigURL = pluginsDirectory
                    .appendingPathComponent(pluginName)
                    .appendingPathComponent("config.json")
                let pluginConfig = PluginConfig.load(fromIfExists: pluginConfigURL)
                let runner = PluginRunner(
                    plugin: loadedPlugin, secrets: secrets, pluginConfig: pluginConfig
                )

                // Build state payload for JSON protocol plugins with dependencies
                let deps = loadedPlugin.manifest.dependencies ?? []
                let proto = loadedPlugin.manifest.hooks[hook]?.pluginProtocol ?? .json
                var pluginState: [String: [String: [String: JSONValue]]]?
                if proto == .json, !deps.isEmpty {
                    var statePayload: [String: [String: [String: JSONValue]]] = [:]
                    for imageName in await stateStore.allImageNames {
                        let resolved = await stateStore.resolve(
                            image: imageName, dependencies: deps
                        )
                        if !resolved.isEmpty {
                            statePayload[imageName] = resolved
                        }
                    }
                    if !statePayload.isEmpty {
                        pluginState = statePayload
                    }
                }

                logger.info("Running plugin '\(pluginName)' for hook '\(hook)'")
                let (result, returnedState) = try await runner.run(
                    hook: hook,
                    tempFolder: temp,
                    executionLogPath: execLogPath,
                    dryRun: dryRun,
                    state: pluginState
                )

                // Store returned state under the plugin's namespace
                if let returnedState {
                    for (imageName, values) in returnedState {
                        let imageExists = FileManager.default.fileExists(
                            atPath: temp.url.appendingPathComponent(imageName).path
                        )
                        if imageExists {
                            await stateStore.setNamespace(
                                image: imageName, plugin: pluginName, values: values
                            )
                        }
                    }
                }

                switch result {
                case .success:
                    logger.info("[\(pluginName)] hook '\(hook)': success")
                case .warning:
                    logger.warning("[\(pluginName)] hook '\(hook)': completed with warnings")
                case .critical:
                    logger.error(
                        "[\(pluginName)] hook '\(hook)': critical failure — aborting pipeline"
                    )
                    blocklist.block(pluginName)
                    return false
                }
            }
        }

        return true
    }

    private func loadPlugin(named name: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(name)
        let manifestURL = pluginDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        return LoadedPlugin(name: name, directory: pluginDir, manifest: manifest)
    }

    /// Fetches all declared secrets for a plugin from the secret store.
    /// Returns the secret map on success.
    /// Throws if any declared secret is missing — missing secrets are a critical failure per spec.
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
                throw SecretStoreError.notFound(key: "piqley.plugins.\(plugin.name).\(key)")
            }
        }
        return result
    }
}
