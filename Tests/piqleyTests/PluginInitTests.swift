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

        // Verify config has values and multiple rules
        let configData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/config.json"))
        let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(config.values.count == 2)
        #expect(config.rules.count == 4)

        // First rule: exact match on camera model
        #expect(config.rules[0].match.field == "original:TIFF:Model")
        #expect(config.rules[0].match.pattern == "Canon EOS R5")
        #expect(config.rules[0].emit.field == "tags")
        #expect(config.rules[0].emit.values == ["Canon", "EOS R5"])

        // Second rule: glob match on lens
        #expect(config.rules[1].match.field == "original:EXIF:LensModel")
        #expect(config.rules[1].match.pattern == "glob:RF*")

        // Third rule: regex match on ISO
        #expect(config.rules[2].match.field == "original:EXIF:ISOSpeedRatings")

        // Fourth rule: emits keywords (no explicit field)
        #expect(config.rules[3].emit.field == nil)
        #expect(config.rules[3].emit.values == ["Portrait"])
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

    // MARK: - parseHookSelection

    @Test("parses single hook number")
    func testParseSingleHook() throws {
        let hooks = Hook.canonicalOrder
        let result = try PluginCommand.InitSubcommand.parseHookSelection("2", from: hooks)
        #expect(result == [hooks[1]])
    }

    @Test("parses range of hooks")
    func testParseHookRange() throws {
        let hooks = Hook.canonicalOrder
        let result = try PluginCommand.InitSubcommand.parseHookSelection("1-4", from: hooks)
        #expect(result == hooks)
    }

    @Test("parses comma-separated hooks")
    func testParseCommaSeparated() throws {
        let hooks = Hook.canonicalOrder
        let result = try PluginCommand.InitSubcommand.parseHookSelection("1,3", from: hooks)
        #expect(result == [hooks[0], hooks[2]])
    }

    @Test("parses mixed commas and ranges")
    func testParseMixedSelection() throws {
        let hooks = Hook.canonicalOrder
        let result = try PluginCommand.InitSubcommand.parseHookSelection("1,3-4", from: hooks)
        #expect(result == [hooks[0], hooks[2], hooks[3]])
    }

    @Test("deduplicates overlapping selections")
    func testDeduplicatesSelection() throws {
        let hooks = Hook.canonicalOrder
        let result = try PluginCommand.InitSubcommand.parseHookSelection("1-3,2", from: hooks)
        #expect(result == [hooks[0], hooks[1], hooks[2]])
    }

    @Test("rejects out-of-range hook number")
    func testRejectsOutOfRange() {
        let hooks = Hook.canonicalOrder
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.parseHookSelection("5", from: hooks)
        }
    }

    @Test("rejects reversed range")
    func testRejectsReversedRange() {
        let hooks = Hook.canonicalOrder
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.parseHookSelection("3-1", from: hooks)
        }
    }

    @Test("rejects non-numeric input")
    func testRejectsNonNumeric() {
        let hooks = Hook.canonicalOrder
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.parseHookSelection("abc", from: hooks)
        }
    }
}
