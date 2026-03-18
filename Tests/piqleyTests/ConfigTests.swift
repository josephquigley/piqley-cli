import Testing
import Foundation
@testable import piqley

@Suite("AppConfig")
struct ConfigTests {
    @Test("decodes pipeline config from JSON")
    func testDecodeFullConfig() throws {
        let json = """
        {
          "autoDiscoverPlugins": true,
          "disabledPlugins": ["bad-plugin"],
          "pipeline": {
            "pre-process": ["piqley-metadata", "piqley-resize"],
            "publish": ["ghost:required"]
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.autoDiscoverPlugins == true)
        #expect(config.disabledPlugins == ["bad-plugin"])
        #expect(config.pipeline["pre-process"] == ["piqley-metadata", "piqley-resize"])
        #expect(config.pipeline["publish"] == ["ghost:required"])
    }

    @Test("defaults autoDiscoverPlugins to true when absent")
    func testDefaults() throws {
        let json = "{}"
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.autoDiscoverPlugins == true)
        #expect(config.disabledPlugins.isEmpty)
        #expect(config.pipeline.isEmpty)
    }

    @Test("encodes and decodes round-trip")
    func testRoundTrip() throws {
        var config = AppConfig()
        config.pipeline["publish"] = ["ghost"]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.pipeline["publish"] == ["ghost"])
    }

    @Test("configURL points to ~/.config/piqley/config.json")
    func testConfigURL() {
        let url = AppConfig.configURL
        #expect(url.lastPathComponent == "config.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "piqley")
    }
}
