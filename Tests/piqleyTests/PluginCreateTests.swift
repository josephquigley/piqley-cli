import Foundation
import Testing
@testable import piqley

@Suite("PluginCreate")
struct PluginCreateTests {
    @Test("derives plugin name from target directory")
    func testNameDerivation() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/my-cool-plugin", "--identifier", "com.example.my-cool-plugin",
        ])
        #expect(cmd.resolvedPluginName == "my-cool-plugin")
    }

    @Test("explicit name overrides derivation")
    func testExplicitName() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/some-dir", "--name", "custom-name", "--identifier", "com.example.custom",
        ])
        #expect(cmd.resolvedPluginName == "custom-name")
    }

    @Test("language defaults to swift")
    func testDefaultLanguage() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--identifier", "com.example.test",
        ])
        #expect(cmd.language == "swift")
    }

    @Test("language is lowercased")
    func testLanguageLowercased() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--language", "Swift", "--identifier", "com.example.test",
        ])
        #expect(cmd.resolvedLanguage == "swift")
    }

    @Test("sdk-repo-url has default value")
    func testDefaultSDKURL() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--identifier", "com.example.test",
        ])
        #expect(cmd.sdkRepoURL == "https://github.com/josephquigley/piqley-plugin-sdk")
    }

    @Test("sdk-repo-url can be overridden")
    func testCustomSDKURL() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--identifier", "com.example.test",
            "--sdk-repo-url", "https://gitlab.example.com/org/sdk",
        ])
        #expect(cmd.sdkRepoURL == "https://gitlab.example.com/org/sdk")
    }

    @Test("validates derived plugin name")
    func testValidatesDerivedName() {
        // "original" is a reserved name
        #expect(throws: (any Error).self) {
            let cmd = try PluginCommand.CreateSubcommand.parse([
                "/tmp/original", "--identifier", "com.example.original",
            ])
            try cmd.validatePluginName()
        }
    }

    @Test("identifier is required")
    func testIdentifierRequired() {
        #expect(throws: (any Error).self) {
            try PluginCommand.CreateSubcommand.parse(["/tmp/test"])
        }
    }

    @Test("identifier is parsed from arguments")
    func testIdentifierParsed() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--identifier", "com.piqley.ghost",
        ])
        #expect(cmd.identifier == "com.piqley.ghost")
    }
}
