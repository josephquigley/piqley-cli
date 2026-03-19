import Foundation
import Testing
@testable import piqley

@Suite("PluginCreate")
struct PluginCreateTests {
    @Test("derives plugin name from target directory")
    func testNameDerivation() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/my-cool-plugin"])
        #expect(cmd.resolvedPluginName == "my-cool-plugin")
    }

    @Test("explicit name overrides derivation")
    func testExplicitName() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/some-dir", "--name", "custom-name"])
        #expect(cmd.resolvedPluginName == "custom-name")
    }

    @Test("language defaults to swift")
    func testDefaultLanguage() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/test"])
        #expect(cmd.language == "swift")
    }

    @Test("language is lowercased")
    func testLanguageLowercased() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/test", "--language", "Swift"])
        #expect(cmd.resolvedLanguage == "swift")
    }

    @Test("sdk-repo-url has default value")
    func testDefaultSDKURL() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/test"])
        #expect(cmd.sdkRepoURL == "https://github.com/josephquigley/piqley-plugin-sdk")
    }

    @Test("sdk-repo-url can be overridden")
    func testCustomSDKURL() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--sdk-repo-url", "https://gitlab.example.com/org/sdk",
        ])
        #expect(cmd.sdkRepoURL == "https://gitlab.example.com/org/sdk")
    }

    @Test("validates derived plugin name")
    func testValidatesDerivedName() {
        // "original" is a reserved name
        #expect(throws: (any Error).self) {
            let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/original"])
            try cmd.validatePluginName()
        }
    }
}
