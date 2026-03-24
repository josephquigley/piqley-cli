import Foundation
import PiqleyCore
import Testing

@testable import piqley

/// In-memory secret store for migration tests.
private final class MigratorMockSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }

    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
    func list() throws -> [String] { Array(secrets.keys) }
}

@Suite("ConfigMigrator")
struct ConfigMigratorTests {
    @Test("Migrates old config.json values to BasePluginConfig")
    func migratesValues() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-migrator-\(UUID().uuidString)")
        let pluginsDir = tempDir.appendingPathComponent("plugins")
        let configDir = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a plugin directory with old config.json and manifest
        let pluginDir = pluginsDir.appendingPathComponent("com.test.plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let oldConfig = PluginConfig(values: ["url": .string("https://example.com")], isSetUp: true)
        try oldConfig.save(to: pluginDir.appendingPathComponent("config.json"))

        // Write manifest with secret entries
        let manifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test Plugin",
            pluginSchemaVersion: "1",
            config: [
                .value(key: "url", type: .string, value: .string("https://default.com")),
                .secret(secretKey: "API_KEY", type: .string),
            ]
        )
        let manifestData = try JSONEncoder.piqley.encode(manifest)
        try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))

        // Set up old-format secret
        let secretStore = MigratorMockSecretStore()
        let oldKey = SecretNamespace.pluginKey(plugin: "com.test.plugin", key: "API_KEY")
        try secretStore.set(key: oldKey, value: "my-secret-value")

        let configStore = BasePluginConfigStore(directory: configDir)

        try ConfigMigrator.migrateIfNeeded(
            pluginsDirectory: pluginsDir,
            configStore: configStore,
            secretStore: secretStore
        )

        // Verify base config was created
        let baseConfig = try configStore.load(for: "com.test.plugin")
        #expect(baseConfig != nil)
        #expect(baseConfig?.values["url"] == .string("https://example.com"))
        #expect(baseConfig?.isSetUp == true)

        // Verify secret was re-keyed
        let newAlias = "com.test.plugin-API_KEY"
        #expect(baseConfig?.secrets["API_KEY"] == newAlias)
        #expect(try secretStore.get(key: newAlias) == "my-secret-value")

        // Verify old config.json was deleted
        #expect(!FileManager.default.fileExists(
            atPath: pluginDir.appendingPathComponent("config.json").path
        ))
    }

    @Test("Skips migration when base config already exists")
    func skipsMigrationWhenBaseExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-migrator-\(UUID().uuidString)")
        let pluginsDir = tempDir.appendingPathComponent("plugins")
        let configDir = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create plugin with old config.json
        let pluginDir = pluginsDir.appendingPathComponent("com.test.plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let oldConfig = PluginConfig(values: ["url": .string("https://old.com")])
        try oldConfig.save(to: pluginDir.appendingPathComponent("config.json"))

        // Pre-create base config (migration should skip)
        let configStore = BasePluginConfigStore(directory: configDir)
        let existingBase = BasePluginConfig(values: ["url": .string("https://existing.com")])
        try configStore.save(existingBase, for: "com.test.plugin")

        let secretStore = MigratorMockSecretStore()

        try ConfigMigrator.migrateIfNeeded(
            pluginsDirectory: pluginsDir,
            configStore: configStore,
            secretStore: secretStore
        )

        // Base config should be unchanged
        let baseConfig = try configStore.load(for: "com.test.plugin")
        #expect(baseConfig?.values["url"] == .string("https://existing.com"))

        // Old config.json should still exist (not deleted since migration was skipped)
        #expect(FileManager.default.fileExists(
            atPath: pluginDir.appendingPathComponent("config.json").path
        ))
    }

    @Test("Handles plugin with no secrets gracefully")
    func migratesWithNoSecrets() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-migrator-\(UUID().uuidString)")
        let pluginsDir = tempDir.appendingPathComponent("plugins")
        let configDir = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginDir = pluginsDir.appendingPathComponent("com.test.plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let oldConfig = PluginConfig(values: ["port": .number(8080)])
        try oldConfig.save(to: pluginDir.appendingPathComponent("config.json"))

        // Manifest with no secrets
        let manifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test Plugin",
            pluginSchemaVersion: "1",
            config: [.value(key: "port", type: .int, value: .number(8080))]
        )
        let manifestData = try JSONEncoder.piqley.encode(manifest)
        try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))

        let secretStore = MigratorMockSecretStore()
        let configStore = BasePluginConfigStore(directory: configDir)

        try ConfigMigrator.migrateIfNeeded(
            pluginsDirectory: pluginsDir,
            configStore: configStore,
            secretStore: secretStore
        )

        let baseConfig = try configStore.load(for: "com.test.plugin")
        #expect(baseConfig?.values["port"] == .number(8080))
        #expect(baseConfig?.secrets.isEmpty == true)
    }

    @Test("Skips migration when no plugins directory exists")
    func skipsWhenNoPluginsDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-migrator-\(UUID().uuidString)")
        let configDir = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginsDir = tempDir.appendingPathComponent("nonexistent")
        let secretStore = MigratorMockSecretStore()
        let configStore = BasePluginConfigStore(directory: configDir)

        // Should not throw
        try ConfigMigrator.migrateIfNeeded(
            pluginsDirectory: pluginsDir,
            configStore: configStore,
            secretStore: secretStore
        )
    }
}
