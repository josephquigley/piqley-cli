import Testing
import Foundation
@testable import piqley

@Suite("PluginManifest")
struct PluginManifestTests {
    @Test("decodes a full manifest")
    func testFullDecode() throws {
        let json = """
        {
          "name": "ghost",
          "pluginProtocolVersion": "1",
          "secrets": ["api-key"],
          "hooks": {
            "publish": {
              "command": "./bin/piqley-ghost",
              "args": ["publish", "$PIQLEY_FOLDER_PATH"],
              "timeout": 60,
              "protocol": "json",
              "successCodes": [0],
              "warningCodes": [2],
              "criticalCodes": [1]
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.name == "ghost")
        #expect(manifest.pluginProtocolVersion == "1")
        #expect(manifest.secrets == ["api-key"])
        let hook = try #require(manifest.hooks["publish"])
        #expect(hook.command == "./bin/piqley-ghost")
        #expect(hook.args == ["publish", "$PIQLEY_FOLDER_PATH"])
        #expect(hook.timeout == 60)
        #expect(hook.pluginProtocol == .json)
        #expect(hook.successCodes == [0])
        #expect(hook.warningCodes == [2])
        #expect(hook.criticalCodes == [1])
    }

    @Test("absent optional fields decode to nil/defaults")
    func testDefaults() throws {
        let json = """
        {
          "name": "minimal",
          "pluginProtocolVersion": "1",
          "hooks": {
            "publish": {
              "command": "./bin/tool",
              "args": []
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.secrets == [])
        let hook = try #require(manifest.hooks["publish"])
        #expect(hook.timeout == nil)
        #expect(hook.pluginProtocol == nil)
        #expect(hook.successCodes == nil)
        #expect(hook.batchProxy == nil)
    }

    @Test("decodes batchProxy with sort config")
    func testBatchProxy() throws {
        let json = """
        {
          "name": "single-image-tool",
          "pluginProtocolVersion": "1",
          "hooks": {
            "pre-process": {
              "command": "/usr/local/bin/tool",
              "args": ["$PIQLEY_IMAGE_PATH"],
              "protocol": "pipe",
              "batchProxy": {
                "sort": {"key": "exif:DateTimeOriginal", "order": "ascending"}
              }
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let hook = try #require(manifest.hooks["pre-process"])
        let proxy = try #require(hook.batchProxy)
        let sort = try #require(proxy.sort)
        #expect(sort.key == "exif:DateTimeOriginal")
        #expect(sort.order == .ascending)
    }

    @Test("makeEvaluator uses Unix defaults when all code arrays are nil")
    func testEvaluatorFromNilCodes() throws {
        let json = """
        {
          "name": "t",
          "pluginProtocolVersion": "1",
          "hooks": {"publish": {"command": "./t", "args": []}}
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let hook = try #require(manifest.hooks["publish"])
        let evaluator = hook.makeEvaluator()
        #expect(evaluator.evaluate(0) == .success)
        #expect(evaluator.evaluate(1) == .critical)
    }

    @Test("unknownHooks returns hook names not in the canonical five")
    func testUnknownHooks() throws {
        let json = """
        {
          "name": "t",
          "pluginProtocolVersion": "1",
          "hooks": {
            "publish": {"command": "./t", "args": []},
            "prepprocess": {"command": "./t", "args": []},
            "foobar": {"command": "./t", "args": []}
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let unknown = manifest.unknownHooks().sorted()
        #expect(unknown == ["foobar", "prepprocess"])
        // Canonical hook is not reported as unknown
        #expect(!unknown.contains("publish"))
    }

    @Test("manifest with unknown hooks still loads successfully")
    func testUnknownHooksDoNotFailLoad() throws {
        let json = """
        {
          "name": "t",
          "pluginProtocolVersion": "1",
          "hooks": {"totally-made-up-hook": {"command": "./t", "args": []}}
        }
        """
        // Should not throw
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.hooks["totally-made-up-hook"] != nil)
    }
}
