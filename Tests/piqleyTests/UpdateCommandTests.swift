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
