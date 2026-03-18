import Testing
import Foundation
import PiqleyCore
import PiqleyPluginSDK
@testable import piqley

@Suite("PluginInit")
struct PluginInitTests {
    @Test("rejects empty name")
    func testRejectsEmptyName() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.validatePluginName("")
        }
    }

    @Test("rejects reserved name 'original'")
    func testRejectsOriginal() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.validatePluginName("original")
        }
    }

    @Test("rejects name with forward slash")
    func testRejectsForwardSlash() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.validatePluginName("../evil")
        }
    }

    @Test("rejects name with backslash")
    func testRejectsBackslash() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.validatePluginName("foo\\bar")
        }
    }

    @Test("rejects name with whitespace")
    func testRejectsWhitespace() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.validatePluginName("my plugin")
        }
    }

    @Test("rejects whitespace-only name")
    func testRejectsWhitespaceOnly() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.validatePluginName("   ")
        }
    }

    @Test("accepts valid plugin name")
    func testAcceptsValidName() throws {
        try PluginCommand.InitSubcommand.validatePluginName("my-plugin")
    }

    /// Creates a unique temp directory for test isolation. Caller is responsible for cleanup.
    func makeTempPluginsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-init-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("non-interactive creates manifest and empty config")
    func testNonInteractiveCreatesFiles() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["test-plugin", "--non-interactive"])
        try cmd.execute(pluginsDirectory: dir)

        // Verify manifest
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("test-plugin/manifest.json"))
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(decoded.name == "test-plugin")
        #expect(decoded.pluginProtocolVersion == "1")
        #expect(decoded.hooks["pre-process"] != nil)
        #expect(decoded.hooks["pre-process"]?.command == nil)

        // Verify config
        let configData = try Data(contentsOf: dir.appendingPathComponent("test-plugin/config.json"))
        let decodedConfig = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(decodedConfig.rules.isEmpty)
    }

    @Test("no-examples flag produces empty rules")
    func testNoExamplesFlag() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["no-ex-plugin", "--no-examples"])
        try cmd.execute(pluginsDirectory: dir)

        let configData = try Data(contentsOf: dir.appendingPathComponent("no-ex-plugin/config.json"))
        let decodedConfig = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(decodedConfig.rules.isEmpty)
    }

    @Test("default mode includes example rule with correct structure")
    func testExampleRuleGeneration() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["example-plugin"])
        try cmd.execute(pluginsDirectory: dir)

        let configData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/config.json"))
        let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(config.rules.count == 1)
        #expect(config.rules[0].match.field == "original:TIFF:Model")
        #expect(config.rules[0].match.pattern == "Canon EOS R5")
        #expect(config.rules[0].emit.field == "tags")
        #expect(config.rules[0].emit.values == ["Canon", "EOS R5"])
    }

    @Test("rejects init when plugin directory already exists")
    func testRejectsExistingDirectory() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-create the plugin directory
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("existing-plugin"),
            withIntermediateDirectories: true
        )

        let cmd = try PluginCommand.InitSubcommand.parse(["existing-plugin", "--non-interactive"])
        #expect(throws: (any Error).self) {
            try cmd.execute(pluginsDirectory: dir)
        }
    }

    @Test("non-interactive without name throws error")
    func testNonInteractiveRequiresName() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["--non-interactive"])
        #expect(throws: (any Error).self) {
            try cmd.execute(pluginsDirectory: dir)
        }
    }
}
