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
}
