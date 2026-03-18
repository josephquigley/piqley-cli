import Testing
import Foundation
@testable import piqley

@Suite("PluginConfig")
struct PluginConfigTests {

    @Test("empty config has no values and nil isSetUp")
    func emptyPluginConfig() {
        let config = PluginConfig()
        #expect(config.values.isEmpty)
        #expect(config.isSetUp == nil)
    }

    @Test("decodes config with values and isSetUp")
    func decodePluginConfig() throws {
        let json = #"{"values": {"url": "https://example.com", "quality": 80}, "isSetUp": true}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.values["url"] == .string("https://example.com"))
        #expect(config.values["quality"] == .number(80))
        #expect(config.isSetUp == true)
    }

    @Test("missing isSetUp decodes as nil")
    func decodePluginConfigMissingIsSetUp() throws {
        let json = #"{"values": {"url": "https://example.com"}}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.isSetUp == nil)
    }

    @Test("save and load round-trip")
    func saveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        var config = PluginConfig()
        config.values["quality"] = .number(80)
        config.isSetUp = true
        try config.save(to: url)

        let loaded = try PluginConfig.load(from: url)
        #expect(loaded.values["quality"] == .number(80))
        #expect(loaded.isSetUp == true)
    }

    @Test("loading from missing file returns empty config")
    func loadFromMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        let config = PluginConfig.load(fromIfExists: url)
        #expect(config.values.isEmpty)
        #expect(config.isSetUp == nil)
    }
}
