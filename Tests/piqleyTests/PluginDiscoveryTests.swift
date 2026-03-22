import Foundation
import PiqleyCore
import Testing
@testable import piqley

private let defaultRegistry = StageRegistry(active: Hook.defaultStageNames.map { StageEntry(name: $0) })

@Suite("PluginDiscovery")
struct PluginDiscoveryTests {
    // Create a temp plugins dir with a given set of plugin subdirs.
    // Each plugin gets a manifest.json and optional stage files.
    func makePluginsDir(plugins: [(name: String, stages: [String])]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for plugin in plugins {
            let pluginDir = dir.appendingPathComponent(plugin.name)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let manifest: [String: Any] = [
                "identifier": plugin.name,
                "name": plugin.name,
                "pluginSchemaVersion": "1",
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: pluginDir.appendingPathComponent("manifest.json"))

            // Create stage files for each requested stage
            for stageName in plugin.stages {
                let stageConfig: [String: Any] = [
                    "binary": ["command": "./bin/tool", "args": []],
                ]
                let stageData = try JSONSerialization.data(withJSONObject: stageConfig)
                try stageData.write(to: pluginDir.appendingPathComponent("stage-\(stageName).json"))
            }
        }
        return dir
    }

    @Test("discovers plugins and loads manifests")
    func testDiscoversPlugins() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", stages: ["publish"]),
            (name: "365-project", stages: ["post-publish"]),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir, registry: defaultRegistry)
        let (plugins, _) = try discovery.loadManifests()
        let names = plugins.map(\.name).sorted()
        #expect(names == ["365-project", "ghost"])
    }

    @Test("skips directories without manifest.json")
    func testSkipsInvalid() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", stages: ["publish"])])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Create a subdir without manifest.json
        let bogus = dir.appendingPathComponent("not-a-plugin")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)

        let discovery = PluginDiscovery(pluginsDirectory: dir, registry: defaultRegistry)
        let (plugins, _) = try discovery.loadManifests()
        #expect(plugins.map(\.name) == ["ghost"])
    }

    @Test("returns empty list when plugins directory does not exist")
    func testMissingDir() throws {
        let dir = URL(fileURLWithPath: "/nonexistent/path/plugins")
        let discovery = PluginDiscovery(pluginsDirectory: dir, registry: defaultRegistry)
        let (plugins, _) = try discovery.loadManifests()
        #expect(plugins.isEmpty)
    }

    @Test("creates data directory for loaded plugins")
    func createsDataDirectory() throws {
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }

        let pluginDir = pluginsDirectory.appendingPathComponent("test-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = #"{"identifier": "test-plugin", "name": "test-plugin", "pluginSchemaVersion": "1"}"#
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let stage = #"{"binary": {"command": "./bin/tool"}}"#
        try stage.write(to: pluginDir.appendingPathComponent("stage-publish.json"), atomically: true, encoding: .utf8)

        let discovery = PluginDiscovery(pluginsDirectory: pluginsDirectory, registry: defaultRegistry)
        _ = try discovery.loadManifests()

        let dataDir = pluginDir.appendingPathComponent("data")
        #expect(FileManager.default.fileExists(atPath: dataDir.path))
    }

    @Test("throws for unsupported schema version")
    func testUnsupportedSchemaVersion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pluginDir = dir.appendingPathComponent("bad-version")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = #"{"identifier": "bad-version", "name": "BadVersion", "pluginSchemaVersion": "999"}"#
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let stage = #"{"binary": {"command": "./bin/tool"}}"#
        try stage.write(to: pluginDir.appendingPathComponent("stage-publish.json"), atomically: true, encoding: .utf8)

        let discovery = PluginDiscovery(pluginsDirectory: dir, registry: defaultRegistry)
        #expect(throws: PluginDiscoveryError.self) {
            try discovery.loadManifests()
        }
    }

    @Test("throws for identifier/directory mismatch")
    func testIdentifierMismatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pluginDir = dir.appendingPathComponent("wrong-dir-name")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = #"{"identifier": "correct-id", "name": "Test", "pluginSchemaVersion": "1"}"#
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let stage = #"{"binary": {"command": "./bin/tool"}}"#
        try stage.write(to: pluginDir.appendingPathComponent("stage-publish.json"), atomically: true, encoding: .utf8)

        let discovery = PluginDiscovery(pluginsDirectory: dir, registry: defaultRegistry)
        #expect(throws: PluginDiscoveryError.self) {
            try discovery.loadManifests()
        }
    }

    @Test("throws for plugin with no stage files")
    func testNoStageFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pluginDir = dir.appendingPathComponent("no-stages")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = #"{"identifier": "no-stages", "name": "NoStages", "pluginSchemaVersion": "1"}"#
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let discovery = PluginDiscovery(pluginsDirectory: dir, registry: defaultRegistry)
        #expect(throws: PluginDiscoveryError.self) {
            try discovery.loadManifests()
        }
    }
}
