import Testing
import Foundation
import PiqleyCore
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
        let config = try JSONDecoder.piqley.decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.values["url"] == .string("https://example.com"))
        #expect(config.values["quality"] == .number(80))
        #expect(config.isSetUp == true)
    }

    @Test("missing isSetUp decodes as nil")
    func decodePluginConfigMissingIsSetUp() throws {
        let json = #"{"values": {"url": "https://example.com"}}"#
        let config = try JSONDecoder.piqley.decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.isSetUp == nil)
    }

    @Test("save and load round-trip")
    func saveAndLoad() throws {
        let fm = InMemoryFileManager()
        let url = URL(fileURLWithPath: "/test/plugin/config.json")
        let config = PluginConfig(values: ["quality": .number(80)], isSetUp: true)
        try config.save(to: url, fileManager: fm)

        let loaded = try PluginConfig.load(from: url, fileManager: fm)
        #expect(loaded.values["quality"] == .number(80))
        #expect(loaded.isSetUp == true)
    }

    @Test("loading from missing file returns empty config")
    func loadFromMissingFileReturnsEmpty() {
        let fm = InMemoryFileManager()
        let url = URL(fileURLWithPath: "/test/nonexistent/config.json")
        let config = PluginConfig.load(fromIfExists: url, fileManager: fm)
        #expect(config.values.isEmpty)
        #expect(config.isSetUp == nil)
    }
}
