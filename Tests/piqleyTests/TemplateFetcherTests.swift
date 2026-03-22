import Foundation
import Testing
@testable import piqley

@Suite("TemplateFetcher")
struct TemplateFetcherTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-template-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("replaces template placeholders in file contents")
    func testTemplateSubstitution() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("test.txt")
        try "name: __PLUGIN_NAME__, version: __SDK_VERSION__".write(to: file, atomically: true, encoding: .utf8)

        try TemplateFetcher.applyTemplateSubstitutions(
            in: dir, pluginName: "my-plugin", sdkVersion: "0.1.0"
        )

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result == "name: my-plugin, version: 0.1.0")
    }

    @Test("substitution handles nested directories")
    func testNestedSubstitution() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let nested = dir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try "__PLUGIN_NAME__".write(to: file, atomically: true, encoding: .utf8)

        try TemplateFetcher.applyTemplateSubstitutions(
            in: dir, pluginName: "test-plug", sdkVersion: "1.0.0"
        )

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result == "test-plug")
    }

    @Test("rejects non-empty target directory")
    func testRejectsNonEmptyTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a file so directory is non-empty
        try "content".write(
            to: dir.appendingPathComponent("existing.txt"),
            atomically: true, encoding: .utf8
        )

        #expect(throws: (any Error).self) {
            try TemplateFetcher.validateTargetDirectory(dir)
        }
    }

    @Test("accepts empty target directory")
    func testAcceptsEmptyTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Should not throw
        try TemplateFetcher.validateTargetDirectory(dir)
    }

    @Test("sanitizes plugin name into valid package name")
    func testSanitizePackageName() {
        #expect(TemplateFetcher.sanitizePackageName("Ghost & 365 Project Publisher") == "ghost-365-project-publisher")
        #expect(TemplateFetcher.sanitizePackageName("My Plugin") == "my-plugin")
        #expect(TemplateFetcher.sanitizePackageName("already-valid") == "already-valid")
        #expect(TemplateFetcher.sanitizePackageName("  Leading & Trailing  ") == "leading-trailing")
        #expect(TemplateFetcher.sanitizePackageName("UPPER_CASE") == "upper-case")
    }

    @Test("substitution replaces package name placeholder")
    func testPackageNameSubstitution() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Package.swift")
        try "name: \"__PLUGIN_PACKAGE_NAME__\"".write(to: file, atomically: true, encoding: .utf8)

        try TemplateFetcher.applyTemplateSubstitutions(
            in: dir, pluginName: "Ghost & 365 Project Publisher", sdkVersion: "0.1.0"
        )

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result == "name: \"ghost-365-project-publisher\"")
    }

    @Test("accepts non-existent target directory")
    func testAcceptsNonExistentTarget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-template-test-\(UUID().uuidString)")
        // Do not create it
        try TemplateFetcher.validateTargetDirectory(dir)
    }
}
