import Foundation
import PiqleyCore
import Testing

@testable import piqley

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Creates a minimal .piqleyplugin zip at the given directory.
/// Returns the URL to the zip file.
private func createPluginZip(
    identifier: String,
    name: String = "Test Plugin",
    version: SemanticVersion? = SemanticVersion(major: 1, minor: 0, patch: 0),
    config: [ConfigEntry] = [],
    setup: SetupConfig? = nil,
    in directory: URL
) throws -> URL {
    let pluginDir = directory.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest = PluginManifest(
        identifier: identifier,
        name: name,
        pluginSchemaVersion: "1",
        pluginVersion: version,
        config: config,
        setup: setup
    )
    let manifestData = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
    try manifestData.write(to: pluginDir.appendingPathComponent(PluginFile.manifest))

    let zipURL = directory.appendingPathComponent("\(identifier).piqleyplugin")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pluginDir.path, zipURL.path]
    try ditto.run()
    ditto.waitUntilExit()

    return zipURL
}

/// Installs a plugin directly by creating its directory and manifest in the plugins dir.
private func preInstallPlugin(
    identifier: String,
    name: String = "Test Plugin",
    version: SemanticVersion? = SemanticVersion(major: 1, minor: 0, patch: 0),
    config: [ConfigEntry] = [],
    setup: SetupConfig? = nil,
    in pluginsDir: URL
) throws {
    let pluginDir = pluginsDir.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest = PluginManifest(
        identifier: identifier,
        name: name,
        pluginSchemaVersion: "1",
        pluginVersion: version,
        config: config,
        setup: setup
    )
    let data = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
    try data.write(to: pluginDir.appendingPathComponent(PluginFile.manifest))
}

// MARK: - Tests

@Suite("PluginUpdater")
struct PluginUpdaterTests {

    @Test("Throws notInstalled when plugin is not installed")
    func notInstalled() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let zipDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: zipDir) }

        let zipURL = try createPluginZip(identifier: "com.test.plugin", in: zipDir)
        let pluginsDir = tempDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        #expect(throws: UpdateError.notInstalled(identifier: "com.test.plugin")) {
            try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)
        }
    }

    @Test("Throws notInstalled when zip identifier differs from installed plugin")
    func differentIdentifierThrowsNotInstalled() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginsDir = tempDir.appendingPathComponent("plugins")
        try preInstallPlugin(identifier: "com.test.old-plugin", in: pluginsDir)

        let zipDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: zipDir) }
        let zipURL = try createPluginZip(identifier: "com.test.new-plugin", in: zipDir)

        #expect(throws: UpdateError.notInstalled(identifier: "com.test.new-plugin")) {
            try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)
        }
    }

    @Test("Successful update returns old and new manifests")
    func successfulUpdate() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginsDir = tempDir.appendingPathComponent("plugins")
        try preInstallPlugin(
            identifier: "com.test.plugin",
            version: SemanticVersion(major: 1, minor: 0, patch: 0),
            config: [.value(key: "old-key", type: .string, value: .string("old"))],
            in: pluginsDir
        )

        let zipDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: zipDir) }
        let zipURL = try createPluginZip(
            identifier: "com.test.plugin",
            version: SemanticVersion(major: 2, minor: 0, patch: 0),
            config: [.value(key: "new-key", type: .string, value: .string("new"))],
            in: zipDir
        )

        let result = try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)
        #expect(result.identifier == "com.test.plugin")
        #expect(result.oldManifest.pluginVersion == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(result.newManifest.pluginVersion == SemanticVersion(major: 2, minor: 0, patch: 0))

        // New manifest is on disk
        let installedManifestURL = pluginsDir
            .appendingPathComponent("com.test.plugin")
            .appendingPathComponent(PluginFile.manifest)
        let data = try Data(contentsOf: installedManifestURL)
        let installed = try JSONDecoder.piqley.decode(PluginManifest.self, from: data)
        #expect(installed.pluginVersion == SemanticVersion(major: 2, minor: 0, patch: 0))
    }
}

@Suite("ConfigMerger")
struct ConfigMergerTests {

    @Test("Kept config values are preserved, new values need prompting, removed values are noted")
    func keptNewAndRemoved() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .value(key: "kept-url", type: .string, value: .string("default")),
                .value(key: "removed-key", type: .int, value: .number(42)),
            ]
        )
        let newManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .value(key: "kept-url", type: .string, value: .string("default")),
                .value(key: "new-key", type: .string, value: .null),
            ]
        )
        let existingConfig = BasePluginConfig(
            values: ["kept-url": .string("https://mysite.com"), "removed-key": .number(99)]
        )

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        // kept-url preserved
        #expect(result.mergedConfig.values["kept-url"] == .string("https://mysite.com"))
        // removed-key gone
        #expect(result.mergedConfig.values["removed-key"] == nil)
        // new-key not in merged config (scanner will prompt)
        #expect(result.mergedConfig.values["new-key"] == nil)
        // Skip sets
        #expect(result.skipValueKeys.contains("kept-url"))
        #expect(!result.skipValueKeys.contains("new-key"))
        // Removed entries
        #expect(result.removedValueKeys.contains("removed-key"))
    }

    @Test("Type change removes old value, records old and new types")
    func typeChange() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [.value(key: "port", type: .string, value: .string("8080"))]
        )
        let newManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [.value(key: "port", type: .int, value: .number(8080))]
        )
        let existingConfig = BasePluginConfig(values: ["port": .string("8080")])

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        // port should not be skipped (type changed)
        #expect(!result.skipValueKeys.contains("port"))
        // port value should be removed from merged config
        #expect(result.mergedConfig.values["port"] == nil)
        // Should record old and new types
        #expect(result.typeChangedKeys["port"]?.0 == .string)
        #expect(result.typeChangedKeys["port"]?.1 == .int)
    }

    @Test("Secret merge: kept secrets preserved, removed secrets noted")
    func secretMerge() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .secret(secretKey: "KEPT_TOKEN", type: .string),
                .secret(secretKey: "OLD_TOKEN", type: .string),
            ]
        )
        let newManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .secret(secretKey: "KEPT_TOKEN", type: .string),
                .secret(secretKey: "NEW_TOKEN", type: .string),
            ]
        )
        let existingConfig = BasePluginConfig(
            secrets: ["KEPT_TOKEN": "alias-kept", "OLD_TOKEN": "alias-old"]
        )

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        #expect(result.mergedConfig.secrets["KEPT_TOKEN"] == "alias-kept")
        #expect(result.mergedConfig.secrets["OLD_TOKEN"] == nil)
        #expect(result.skipSecretKeys.contains("KEPT_TOKEN"))
        #expect(!result.skipSecretKeys.contains("NEW_TOKEN"))
        #expect(result.removedSecretKeys.contains("OLD_TOKEN"))
    }

    @Test("isSetUp is reset to nil during merge")
    func isSetUpReset() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [.value(key: "url", type: .string, value: .string("x"))]
        )
        let newManifest = oldManifest
        let existingConfig = BasePluginConfig(
            values: ["url": .string("https://example.com")],
            isSetUp: true
        )

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        #expect(result.mergedConfig.isSetUp == nil)
    }
}
