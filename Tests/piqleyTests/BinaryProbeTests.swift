import Foundation
import Testing

@testable import piqley

@Suite("BinaryProbe")
struct BinaryProbeTests {
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-binary-probe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test("probe returns .notFound for non-existent path")
    func testNotFound() {
        let result = BinaryProbe.probe(
            command: "/nonexistent/path/to/binary",
            pluginDirectory: tempDir
        )
        #expect(result == .notFound)
    }

    @Test("probe returns .notExecutable for file without +x")
    func testNotExecutable() throws {
        let filePath = tempDir.appendingPathComponent("not-executable")
        FileManager.default.createFile(atPath: filePath.path, contents: Data("hello".utf8))
        // Ensure not executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: filePath.path
        )

        let result = BinaryProbe.probe(
            command: filePath.path,
            pluginDirectory: tempDir
        )
        #expect(result == .notExecutable)
    }

    @Test("probe returns .cliTool for a binary that doesn't respond to --piqley-info")
    func testCliTool() {
        let result = BinaryProbe.probe(
            command: "/bin/echo",
            pluginDirectory: tempDir
        )
        #expect(result == .cliTool)
    }

    @Test("resolveExecutable returns absolute path as-is")
    func testResolveExecutableAbsolute() {
        let path = BinaryProbe.resolveExecutable(
            "/usr/bin/exiftool", pluginDirectory: tempDir
        )
        #expect(path == "/usr/bin/exiftool")
    }

    @Test("resolveExecutable resolves relative path against plugin dir")
    func testResolveExecutableRelative() {
        let path = BinaryProbe.resolveExecutable(
            "./bin/my-plugin", pluginDirectory: tempDir
        )
        #expect(path == tempDir.appendingPathComponent("./bin/my-plugin").path)
    }
}
