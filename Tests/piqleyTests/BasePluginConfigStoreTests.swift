import Foundation
import PiqleyCore
import Testing

@testable import piqley

@Suite("BasePluginConfigStore")
struct BasePluginConfigStoreTests {
    @Test("Saves and loads base config")
    func saveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BasePluginConfigStore(directory: dir)
        let config = BasePluginConfig(
            values: ["url": .string("https://example.com")],
            secrets: ["API_KEY": "my-alias"],
            isSetUp: true
        )
        try store.save(config, for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == config)
    }

    @Test("Load returns nil for missing config")
    func loadMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BasePluginConfigStore(directory: dir)
        let loaded = try store.load(for: "com.test.missing")
        #expect(loaded == nil)
    }

    @Test("Delete removes config file")
    func deleteConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BasePluginConfigStore(directory: dir)
        let config = BasePluginConfig(values: ["k": .string("v")], secrets: [:])
        try store.save(config, for: "com.test.plugin")
        try store.delete(for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == nil)
    }

    @Test("Save creates directory if it does not exist")
    func savesCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let store = BasePluginConfigStore(directory: dir)
        let config = BasePluginConfig(values: ["k": .string("v")], secrets: [:])
        try store.save(config, for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == config)
    }
}
