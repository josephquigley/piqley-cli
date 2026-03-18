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

                // Fetch secrets from Keychain — missing secret is a critical failure
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

                let pluginConfig = config.plugins[pluginName] ?? [:]
                let runner = PluginRunner(plugin: loadedPlugin, secrets: secrets)

                logger.info("Running plugin '\(pluginName)' for hook '\(hook)'")
                let result = try await runner.run(
                    hook: hook,
                    tempFolder: temp,
                    pluginConfig: pluginConfig,
                    executionLogPath: execLogPath,
                    dryRun: dryRun
                )

                switch result {
                case .success:
                    logger.info("[\(pluginName)] hook '\(hook)': success")
                case .warning:
                    logger.warning("[\(pluginName)] hook '\(hook)': completed with warnings")
                case .critical:
                    logger.error("[\(pluginName)] hook '\(hook)': critical failure — aborting pipeline")
                    blocklist.block(pluginName)
                    return false
                }
            }
        }

        return true
    }

    private func loadPlugin(named name: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(name)
        let manifestURL = pluginDir.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        return LoadedPlugin(name: name, directory: pluginDir, manifest: manifest)
    }

    /// Fetches all declared secrets for a plugin from the Keychain.
    /// Returns the secret map on success.
    /// Throws if any declared secret is missing — missing secrets are a critical failure per spec.
    private func fetchSecrets(for plugin: LoadedPlugin) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secrets {
            do {
                let value = try secretStore.getPluginSecret(plugin: plugin.name, key: key)
                result[key] = value
            } catch {
                logger.error("[\(plugin.name)] required secret '\(key)' not found in Keychain: \(error)")
                logger.error("Run 'piqley secret set \(plugin.name) \(key)' to configure it.")
                throw SecretStoreError.notFound(key: "piqley.plugins.\(plugin.name).\(key)")
            }
        }
        return result
    }
}
