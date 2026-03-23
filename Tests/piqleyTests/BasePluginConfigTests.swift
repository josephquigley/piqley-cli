import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("BasePluginConfig")
struct BasePluginConfigTests {
    @Test("Encodes and decodes with values and secrets")
    func roundTrip() throws {
        let config = BasePluginConfig(
            values: ["url": .string("https://example.com"), "quality": .number(85)],
            secrets: ["API_KEY": "my-plugin-API_KEY"],
            isSetUp: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BasePluginConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("Decodes with empty values and secrets")
    func decodesEmpty() throws {
        let json = Data(#"{"values":{},"secrets":{}}"#.utf8)
        let config = try JSONDecoder().decode(BasePluginConfig.self, from: json)
        #expect(config.values.isEmpty)
        #expect(config.secrets.isEmpty)
        #expect(config.isSetUp == nil)
    }

    @Test("Merges workflow overrides on top of base")
    func mergeOverrides() {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com"), "quality": .number(85)],
            secrets: ["API_KEY": "prod-key"],
            isSetUp: true
        )
        let overrides = WorkflowPluginConfig(
            values: ["url": .string("https://staging.com")],
            secrets: ["API_KEY": "staging-key"]
        )
        let merged = base.merging(overrides)
        #expect(merged.values["url"] == .string("https://staging.com"))
        #expect(merged.values["quality"] == .number(85))
        #expect(merged.secrets["API_KEY"] == "staging-key")
    }

    @Test("Merge with nil overrides returns base values")
    func mergeNilOverrides() {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com")],
            secrets: ["API_KEY": "prod-key"],
            isSetUp: true
        )
        let overrides = WorkflowPluginConfig(values: nil, secrets: nil)
        let merged = base.merging(overrides)
        #expect(merged.values["url"] == .string("https://prod.com"))
        #expect(merged.secrets["API_KEY"] == "prod-key")
    }
}
