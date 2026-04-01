import Foundation
import PiqleyCore
import Testing

@testable import piqley

@Suite("BasePluginConfigStore")
struct BasePluginConfigStoreTests {
    @Test("Saves and loads base config")
    func saveAndLoad() throws {
        let fm = InMemoryFileManager()
        let dir = URL(fileURLWithPath: "/test/config")
        let store = BasePluginConfigStore(directory: dir, fileManager: fm)
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
        let fm = InMemoryFileManager()
        let dir = URL(fileURLWithPath: "/test/config")
        let store = BasePluginConfigStore(directory: dir, fileManager: fm)
        let loaded = try store.load(for: "com.test.missing")
        #expect(loaded == nil)
    }

    @Test("Delete removes config file")
    func deleteConfig() throws {
        let fm = InMemoryFileManager()
        let dir = URL(fileURLWithPath: "/test/config")
        let store = BasePluginConfigStore(directory: dir, fileManager: fm)
        let config = BasePluginConfig(values: ["k": .string("v")], secrets: [:])
        try store.save(config, for: "com.test.plugin")
        try store.delete(for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == nil)
    }

    @Test("Save creates directory if it does not exist")
    func savesCreatesDirectory() throws {
        let fm = InMemoryFileManager()
        let dir = URL(fileURLWithPath: "/test/config/nested")
        let store = BasePluginConfigStore(directory: dir, fileManager: fm)
        let config = BasePluginConfig(values: ["k": .string("v")], secrets: [:])
        try store.save(config, for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == config)
    }
}
