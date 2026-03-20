import Foundation
import Testing
@testable import piqley

@Suite("AppConfig")
struct ConfigTests {
    @Test("decodes pipeline-only config from JSON")
    func testDecodePipelineConfig() throws {
        let json = """
        {
          "pipeline": {
            "pre-process": ["piqley-metadata", "piqley-resize"],
            "publish": ["ghost"]
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.pipeline["pre-process"] == ["piqley-metadata", "piqley-resize"])
        #expect(config.pipeline["publish"] == ["ghost"])
    }

    @Test("decodes empty JSON with empty pipeline")
    func testEmptyDefaults() throws {
        let json = "{}"
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
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
