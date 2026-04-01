import Foundation
import Logging
import PiqleyCore

/// Migrates plugins from the old config.json sidecar format to the new
/// BasePluginConfig layout at ~/.config/piqley/config/.
enum ConfigMigrator {
    private static let logger = Logger(label: "piqley.config-migrator")

    /// Scans installed plugins for old config.json sidecars and migrates them
    /// to BasePluginConfig files. Skips plugins that already have a base config.
    static func migrateIfNeeded(
        pluginsDirectory: URL,
        configStore: BasePluginConfigStore,
        secretStore: any SecretStore,
        fileManager: any FileSystemManager = FileManager.default
    ) throws {
        guard fileManager.fileExists(atPath: pluginsDirectory.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )

        for pluginURL in contents {
            guard (try? pluginURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let identifier = pluginURL.lastPathComponent
            let oldConfigURL = pluginURL.appendingPathComponent(PluginFile.config)

            // Only migrate if old config.json exists and no base config yet
            guard fileManager.fileExists(atPath: oldConfigURL.path) else { continue }
            if let existing = try configStore.load(for: identifier), !existing.values.isEmpty || existing.isSetUp != nil {
                continue
            }

            try migratePlugin(
                identifier: identifier,
                pluginDirectory: pluginURL,
                oldConfigURL: oldConfigURL,
                configStore: configStore,
                secretStore: secretStore,
                fileManager: fileManager
            )
        }
    }

    private static func migratePlugin(
        identifier: String,
        pluginDirectory: URL,
        oldConfigURL: URL,
        configStore: BasePluginConfigStore,
        secretStore: any SecretStore,
        fileManager: any FileSystemManager = FileManager.default
    ) throws {
        logger.info("Migrating config for plugin '\(identifier)'")

        // Read old config.json
        let oldData = try fileManager.contents(of: oldConfigURL)
        let oldConfig = try JSONDecoder.piqley.decode(PluginConfig.self, from: oldData)

        // Read manifest to find secret keys
        var secretAliases: [String: String] = [:]
        let manifestURL = pluginDirectory.appendingPathComponent(PluginFile.manifest)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifestData = try fileManager.contents(of: manifestURL)
            let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)

            for entry in manifest.config {
                guard case let .secret(secretKey, _, _) = entry else { continue }

                // Re-key secret from old format to alias format
                let oldKey = SecretNamespace.pluginKey(plugin: identifier, key: secretKey)
                let newAlias = PluginSetupScanner.defaultSecretAlias(
                    pluginIdentifier: identifier, secretKey: secretKey
                )

                if let value = try? secretStore.get(key: oldKey) {
                    try secretStore.set(key: newAlias, value: value)
                    try? secretStore.delete(key: oldKey)
                }

                secretAliases[secretKey] = newAlias
            }
        }

        // Write new base config
        let baseConfig = BasePluginConfig(
            values: oldConfig.values,
            secrets: secretAliases,
            isSetUp: oldConfig.isSetUp
        )
        try configStore.save(baseConfig, for: identifier)

        // Delete old config.json
        try fileManager.removeItem(at: oldConfigURL)

        logger.info("Migrated config for plugin '\(identifier)'")
    }
}
