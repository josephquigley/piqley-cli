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

    @Test("sanitizes forward slashes")
    func testSanitizesForwardSlash() throws {
        let result = try PluginCommand.InitSubcommand.sanitizePluginIdentifier("../evil")
        #expect(result == "..evil")
    }

    @Test("sanitizes backslashes")
    func testSanitizesBackslash() throws {
        let result = try PluginCommand.InitSubcommand.sanitizePluginIdentifier("foo\\bar")
        #expect(result == "foobar")
    }

    @Test("sanitizes whitespace")
    func testSanitizesWhitespace() throws {
        let result = try PluginCommand.InitSubcommand.sanitizePluginIdentifier("my plugin")
        #expect(result == "myplugin")
    }

    @Test("rejects whitespace-only name")
    func testRejectsWhitespaceOnly() {
        #expect(throws: (any Error).self) {
            try PluginCommand.InitSubcommand.sanitizePluginIdentifier("   ")
        }
    }

    @Test("lowercases identifier")
    func testLowercases() throws {
        let result = try PluginCommand.InitSubcommand.sanitizePluginIdentifier("Com.Example.MyPlugin")
        #expect(result == "com.example.myplugin")
    }

    @Test("preserves dots, dashes, and underscores")
    func testPreservesAllowedSymbols() throws {
        let result = try PluginCommand.InitSubcommand.sanitizePluginIdentifier("com.my-plugin_v2")
        #expect(result == "com.my-plugin_v2")
    }

    @Test("accepts valid plugin name")
    func testAcceptsValidName() throws {
        let result = try PluginCommand.InitSubcommand.sanitizePluginIdentifier("my-plugin")
        #expect(result == "my-plugin")
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
        #expect(decoded.identifier == "test-plugin")
        #expect(decoded.name == "test-plugin")
        #expect(decoded.pluginSchemaVersion == "1")

        // Non-interactive: no stage files created
        let stageFile = dir.appendingPathComponent("test-plugin/stage-pre-process.json")
        #expect(!FileManager.default.fileExists(atPath: stageFile.path))

        // Verify config has no rules (rules moved to stage files)
        let configData = try Data(contentsOf: dir.appendingPathComponent("test-plugin/config.json"))
        let decodedConfig = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(decodedConfig.values.isEmpty)
    }

    @Test("no-examples flag produces no stage files")
    func testNoExamplesFlag() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["no-ex-plugin", "--no-examples"])
        try cmd.execute(pluginsDirectory: dir, descriptionPrompt: { _ in nil })

        // No stage files when examples are skipped
        let stageFile = dir.appendingPathComponent("no-ex-plugin/stage-pre-process.json")
        #expect(!FileManager.default.fileExists(atPath: stageFile.path))
    }

    @Test("default mode creates manifest, config, and stage files")
    func testExampleRuleGeneration() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["example-plugin"])
        try cmd.execute(pluginsDirectory: dir, descriptionPrompt: { _ in nil })

        // Verify manifest
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(manifest.identifier == "example-plugin")
        #expect(manifest.pluginVersion != nil)
        #expect(manifest.config.count == 3)

        // Verify config has values (no rules — rules in stage files)
        let configData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/config.json"))
        let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
        #expect(config.values.count == 2)

        // Verify pre-process stage file was created with rules
        let preStageURL = dir.appendingPathComponent("example-plugin/stage-pre-process.json")
        #expect(FileManager.default.fileExists(atPath: preStageURL.path))
        let preStageData = try Data(contentsOf: preStageURL)
        let preStage = try JSONDecoder().decode(StageConfig.self, from: preStageData)
        let preRules = try #require(preStage.preRules)
        #expect(!preRules.isEmpty)

        // Verify post-process stage file was created
        let postStageURL = dir.appendingPathComponent("example-plugin/stage-post-process.json")
        #expect(FileManager.default.fileExists(atPath: postStageURL.path))
        let postStageData = try Data(contentsOf: postStageURL)
        let postStage = try JSONDecoder().decode(StageConfig.self, from: postStageData)
        let postRules = try #require(postStage.postRules)
        #expect(!postRules.isEmpty)

        // Spot-check first pre-process rule
        #expect(preRules[0].match.field == "original:TIFF:Model")
        #expect(preRules[0].match.pattern == "Canon EOS R5")
        #expect(preRules[0].emit[0].values == ["Canon", "EOS R5"])

        // Spot-check post-process write action
        let writeRule = postRules.first { !$0.write.isEmpty }
        #expect(writeRule != nil)
        #expect(writeRule?.write[0].field == "IPTC:Keywords")

        // Verify empty stage files for remaining stages
        let publishStageURL = dir.appendingPathComponent("example-plugin/stage-publish.json")
        #expect(FileManager.default.fileExists(atPath: publishStageURL.path))

        let postPublishStageURL = dir.appendingPathComponent("example-plugin/stage-post-publish.json")
        #expect(FileManager.default.fileExists(atPath: postPublishStageURL.path))
    }

    @Test("description from prompt is written to manifest")
    func testDescriptionWrittenToManifest() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["desc-plugin", "--no-examples"])
        try cmd.execute(pluginsDirectory: dir, descriptionPrompt: { _ in "A cool plugin\nfor photographers." })

        let manifestData = try Data(contentsOf: dir.appendingPathComponent("desc-plugin/manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(manifest.description == "A cool plugin\nfor photographers.")
    }

    @Test("nil description is omitted from manifest")
    func testNilDescriptionOmitted() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["no-desc-plugin", "--no-examples"])
        try cmd.execute(pluginsDirectory: dir, descriptionPrompt: { _ in nil })

        let manifestData = try Data(contentsOf: dir.appendingPathComponent("no-desc-plugin/manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(manifest.description == nil)
    }

    @Test("--description flag overrides prompt")
    func testDescriptionFlag() throws {
        let dir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cmd = try PluginCommand.InitSubcommand.parse(["flag-plugin", "--description", "From flag", "--non-interactive"])
        try cmd.execute(pluginsDirectory: dir)

        let manifestData = try Data(contentsOf: dir.appendingPathComponent("flag-plugin/manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(manifest.description == "From flag")
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
