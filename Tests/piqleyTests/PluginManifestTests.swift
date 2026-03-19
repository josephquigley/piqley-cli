import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("PluginManifest")
struct PluginManifestTests {
    @Test("decodes a full manifest")
    func testFullDecode() throws {
        let json = """
        {
          "identifier": "com.piqley.ghost",
          "name": "ghost",
          "pluginProtocolVersion": "1",
          "config": [{"secret_key": "api-key", "type": "string"}]
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.identifier == "com.piqley.ghost")
        #expect(manifest.name == "ghost")
        #expect(manifest.pluginProtocolVersion == "1")
        #expect(manifest.secretKeys == ["api-key"])
    }

    @Test("absent optional fields decode to nil/defaults")
    func testDefaults() throws {
        let json = """
        {
          "identifier": "com.piqley.minimal",
          "name": "minimal",
          "pluginProtocolVersion": "1"
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.config.isEmpty)
        #expect(manifest.setup == nil)
    }

    @Test("makeEvaluator uses Unix defaults when all code arrays are nil")
    func testEvaluatorFromNilCodes() throws {
        let hookConfig = HookConfig(command: "./t", args: [])
        let evaluator = hookConfig.makeEvaluator()
        #expect(evaluator.evaluate(0) == .success)
        #expect(evaluator.evaluate(1) == .critical)
    }

    @Test("decodes config array with value and secret entries")
    func testConfigArrayDecoding() throws {
        let json = """
        {
          "identifier": "com.piqley.test-plugin",
          "name": "test-plugin",
          "pluginProtocolVersion": "1",
          "config": [
            {"key": "base-url", "type": "string", "value": "https://example.com"},
            {"secret_key": "api-key", "type": "string"},
            {"key": "retry-count", "type": "int", "value": 3}
          ]
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.config.count == 3)
        #expect(manifest.secretKeys == ["api-key"])
        #expect(manifest.valueEntries.count == 2)
        #expect(manifest.valueEntries[0].key == "base-url")
        #expect(manifest.valueEntries[1].key == "retry-count")
    }

    @Test("decodes manifest with setup object")
    func testSetupDecoding() throws {
        let json = """
        {
          "identifier": "com.piqley.test-plugin",
          "name": "test-plugin",
          "pluginProtocolVersion": "1",
          "setup": {"command": "./setup.sh", "args": ["--install"]}
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let setup = try #require(manifest.setup)
        #expect(setup.command == "./setup.sh")
        #expect(setup.args == ["--install"])
    }

    @Test("secretKeys computed property returns only secret entry keys")
    func testSecretKeys() throws {
        let json = """
        {
          "identifier": "com.piqley.t",
          "name": "t",
          "pluginProtocolVersion": "1",
          "config": [
            {"key": "base-url", "type": "string", "value": "https://example.com"},
            {"secret_key": "api-key", "type": "string"},
            {"secret_key": "webhook-secret", "type": "string"}
          ]
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.secretKeys.sorted() == ["api-key", "webhook-secret"])
    }

    @Test("valueEntries computed property returns only value entries")
    func testValueEntries() throws {
        let json = """
        {
          "identifier": "com.piqley.t",
          "name": "t",
          "pluginProtocolVersion": "1",
          "config": [
            {"key": "base-url", "type": "string", "value": "https://example.com"},
            {"secret_key": "api-key", "type": "string"},
            {"key": "enabled", "type": "bool", "value": true}
          ]
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.valueEntries.count == 2)
        #expect(manifest.valueEntries[0].key == "base-url")
        #expect(manifest.valueEntries[1].key == "enabled")
    }

    @Test("backward compat: manifest with no config or setup uses defaults")
    func testBackwardCompat() throws {
        let json = """
        {
          "identifier": "com.piqley.legacy",
          "name": "legacy",
          "pluginProtocolVersion": "1"
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.config.isEmpty)
        #expect(manifest.setup == nil)
        #expect(manifest.secretKeys.isEmpty)
        #expect(manifest.valueEntries.isEmpty)
    }

    @Test("decodes manifest with dependencies")
    func testDependencies() throws {
        let json = """
        {
          "identifier": "com.piqley.flickr",
          "name": "flickr",
          "pluginProtocolVersion": "1",
          "dependencies": ["hashtag", "original"]
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.dependencyIdentifiers == ["hashtag", "original"])
    }

    @Test("absent dependencies decodes to nil")
    func testNoDependencies() throws {
        let json = """
        {
          "identifier": "com.piqley.simple",
          "name": "simple",
          "pluginProtocolVersion": "1"
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.dependencies == nil)
    }

    @Test("description field decodes when present")
    func testDescriptionDecoding() throws {
        let json = """
        {
          "identifier": "com.piqley.desc-test",
          "name": "desc-test",
          "description": "A test plugin",
          "pluginProtocolVersion": "1"
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.description == "A test plugin")
    }
}
