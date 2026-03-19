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
        let config = PluginConfig(values: ["quality": .number(80)], isSetUp: true)
        try config.save(to: url)

        let loaded = try PluginConfig.load(from: url)
        #expect(loaded.values["quality"] == .number(80))
        #expect(loaded.isSetUp == true)
    }

    @Test("config with rules decodes")
    func decodeWithRules() throws {
        let json = """
        {
            "values": {},
            "rules": [
                {
                    "match": {"field": "original:TIFF:Model", "pattern": "Sony"},
                    "emit": [{"field": "keywords", "values": ["sony"]}]
                }
            ]
        }
        """
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.rules.count == 1)
        #expect(config.rules[0].match.field == "original:TIFF:Model")
    }

    @Test("config without rules defaults to empty")
    func decodeWithoutRulesDefaultsEmpty() throws {
        let json = #"{"values": {"url": "https://example.com"}}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.rules.isEmpty)
    }

    @Test("round-trip with rules")
    func roundTripWithRules() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        let config = PluginConfig(rules: [
            Rule(
                match: MatchConfig(hook: "pre-process", field: "original:TIFF:Model", pattern: "Sony"),
                emit: [EmitConfig(field: "keywords", values: ["sony"])]
            )
        ])
        try config.save(to: url)

        let loaded = try PluginConfig.load(from: url)
        #expect(loaded.rules.count == 1)
        #expect(loaded.rules[0].emit[0].values == ["sony"])
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
