import Testing
import Foundation
@testable import piqley

@Suite("PluginDiscovery")
struct PluginDiscoveryTests {
    // Create a temp plugins dir with a given set of plugin subdirs (each with a manifest.json)
    func makePluginsDir(plugins: [(name: String, hooks: [String])]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for plugin in plugins {
            let pluginDir = dir.appendingPathComponent(plugin.name)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            var hooksDict: [String: Any] = [:]
            for hook in plugin.hooks {
                hooksDict[hook] = ["command": "./bin/tool", "args": []]
            }
            let manifest: [String: Any] = [
                "name": plugin.name,
                "pluginProtocolVersion": "1",
                "hooks": hooksDict
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: pluginDir.appendingPathComponent("manifest.json"))
        }
        return dir
    }

    @Test("discovers plugins and loads manifests")
    func testDiscoversPlugins() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", hooks: ["publish", "schedule"]),
            (name: "365-project", hooks: ["post-publish"])
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
            (name: "ghost", hooks: ["publish"]),
            (name: "disabled-plugin", hooks: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: ["disabled-plugin"])
        #expect(plugins.map(\.name) == ["ghost"])
    }

    @Test("skips directories without manifest.json")
    func testSkipsInvalid() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", hooks: ["publish"])])
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
            (name: "ghost", hooks: ["publish"]),
            (name: "365-project", hooks: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])

        var pipeline: [String: [String]] = ["publish": ["existing-plugin"]]
        PluginDiscovery.autoAppend(discovered: plugins, into: &pipeline)

        // ghost publishes — should be appended to "publish" (already has existing-plugin)
        #expect(pipeline["publish"] == ["existing-plugin", "ghost"])
        // 365-project post-publishes — new entry
        #expect(pipeline["post-publish"] == ["365-project"])
    }

    @Test("autoAppend does not duplicate already-listed plugins")
    func testNoDuplicates() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", hooks: ["publish"])])
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
}
