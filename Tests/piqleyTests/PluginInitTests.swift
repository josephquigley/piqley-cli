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
        #expect(decoded.hooks.count == Hook.canonicalOrder.count)
        for hook in Hook.canonicalOrder {
            #expect(decoded.hooks[hook.rawValue]?.command == nil)
        }

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

    @Test("default mode includes example rules with correct structure")
    func testExampleRuleGeneration() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["example-plugin"])
        try cmd.execute(pluginsDirectory: dir)

        // Verify manifest has full example fields
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(manifest.pluginVersion != nil)
        #expect(manifest.config.count == 3)
        #expect(manifest.dependencies == ["example-dependency"])

        // Verify both hooks have example command
        let preHook = manifest.hooks["pre-process"]
        #expect(preHook?.command == "echo")
        #expect(preHook?.args == ["[pre-process]", "tags: Canon, EOS R5, RF Mount, High ISO, Portrait, Piqley Emulsions LLC"])
        #expect(preHook?.timeout == 30)
        let postHook = manifest.hooks["post-process"]
        #expect(postHook?.command == "echo")

        // Verify config has values and rules
        let configData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/config.json"))
        let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(config.values.count == 2)
        #expect(config.rules.count == 6)

        // Pre-process rules: tag from original metadata
        #expect(config.rules[0].match.field == "original:TIFF:Model")
        #expect(config.rules[0].match.pattern == "Canon EOS R5")
        #expect(config.rules[0].match.hook == "pre-process")
        #expect(config.rules[0].emit.values == ["Canon", "EOS R5"])

        #expect(config.rules[1].match.field == "original:EXIF:LensModel")
        #expect(config.rules[1].match.pattern == "glob:RF*")

        #expect(config.rules[2].match.field == "original:EXIF:ISOSpeedRatings")

        #expect(config.rules[3].emit.field == nil)
        #expect(config.rules[3].emit.values == ["Portrait"])

        // Pre-process: inject legacy film company tag
        #expect(config.rules[4].match.field == "original:TIFF:Make")
        #expect(config.rules[4].match.pattern == "glob:*Kodak*")
        #expect(config.rules[4].emit.values == ["Kodak"])

        // Post-process: remap Kodak tag via self-dependency
        #expect(config.rules[5].match.field == "example-plugin:tags")
        #expect(config.rules[5].match.pattern == "Kodak")
        #expect(config.rules[5].match.hook == "post-process")
        #expect(config.rules[5].emit.values == ["Piqley Emulsions, LLC"])
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
