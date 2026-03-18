import Testing
import Foundation
@testable import piqley

@Suite("AppConfig")
struct ConfigTests {
    @Test("decodes pipeline and plugin config from JSON")
    func testDecodeFullConfig() throws {
        let json = """
        {
          "autoDiscoverPlugins": true,
          "disabledPlugins": ["bad-plugin"],
          "pipeline": {
            "pre-process": ["piqley-metadata", "piqley-resize"],
            "publish": ["ghost:required"]
          },
          "plugins": {
            "piqley-resize": {"maxLongEdge": 2048, "quality": 85}
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.autoDiscoverPlugins == true)
        #expect(config.disabledPlugins == ["bad-plugin"])
        #expect(config.pipeline["pre-process"] == ["piqley-metadata", "piqley-resize"])
        #expect(config.pipeline["publish"] == ["ghost:required"])
        if case .number(let quality) = config.plugins["piqley-resize"]?["quality"] {
            #expect(quality == 85)
        } else {
            Issue.record("Expected quality to be a number")
        }
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
        config.plugins["ghost"] = ["url": .string("https://example.com")]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.pipeline["publish"] == ["ghost"])
        if case .string(let url) = decoded.plugins["ghost"]?["url"] {
            #expect(url == "https://example.com")
        } else {
            Issue.record("Expected url to be a string")
        }
    }

    @Test("configURL points to ~/.config/piqley/config.json")
    func testConfigURL() {
        let url = AppConfig.configURL
        #expect(url.lastPathComponent == "config.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "piqley")
    }
}
