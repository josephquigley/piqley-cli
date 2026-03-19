import Testing
import Foundation
import PiqleyCore
@testable import piqley

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
                "pluginProtocolVersion": "1"
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: pluginDir.appendingPathComponent("manifest.json"))

            // Create stage files for each requested stage
            for stageName in plugin.stages {
                let stageConfig: [String: Any] = [
                    "binary": ["command": "./bin/tool", "args": []]
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
            (name: "365-project", stages: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])
        let names = plugins.map(\.name).sorted()
        #expect(names == ["365-project", "ghost"])
    }

    @Test("skips disabled plugins")
    func testDisabled() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", stages: ["publish"]),
            (name: "disabled-plugin", stages: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: ["disabled-plugin"])
        #expect(plugins.map(\.name) == ["ghost"])
    }

    @Test("skips directories without manifest.json")
    func testSkipsInvalid() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", stages: ["publish"])])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Create a subdir without manifest.json
        let bogus = dir.appendingPathComponent("not-a-plugin")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])
        #expect(plugins.map(\.name) == ["ghost"])
    }

    @Test("autoAppend adds plugins not already in pipeline lists")
    func testAutoAppend() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", stages: ["publish"]),
            (name: "365-project", stages: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])

        var pipeline: [String: [String]] = ["publish": ["existing-plugin"]]
        PluginDiscovery.autoAppend(discovered: plugins, into: &pipeline)

        // ghost participates in publish — should be appended (existing-plugin already there)
        #expect(pipeline["publish"] == ["existing-plugin", "ghost"])
        // 365-project participates in post-publish — new entry
        #expect(pipeline["post-publish"] == ["365-project"])
    }

    @Test("autoAppend does not duplicate already-listed plugins")
    func testNoDuplicates() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", stages: ["publish"])])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])

        var pipeline: [String: [String]] = ["publish": ["ghost"]]
        PluginDiscovery.autoAppend(discovered: plugins, into: &pipeline)
        #expect(pipeline["publish"] == ["ghost"])
    }

    @Test("returns empty list when plugins directory does not exist")
    func testMissingDir() throws {
        let dir = URL(fileURLWithPath: "/nonexistent/path/plugins")
        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])
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
        let manifest = #"{"identifier": "test-plugin", "name": "test-plugin", "pluginProtocolVersion": "1"}"#
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let discovery = PluginDiscovery(pluginsDirectory: pluginsDirectory)
        _ = try discovery.loadManifests(disabled: [])

        let dataDir = pluginDir.appendingPathComponent("data")
        #expect(FileManager.default.fileExists(atPath: dataDir.path))
    }
}
