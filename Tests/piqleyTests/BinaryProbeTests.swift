import Foundation
import PiqleyCore
import Testing

@testable import piqley

@Suite("BinaryProbe")
struct BinaryProbeTests {

    @Test("probe returns .notFound for non-existent path")
    func testNotFound() {
        let fm = InMemoryFileManager()
        let pluginDir = URL(fileURLWithPath: "/test/plugins/test-plugin")
        let result = BinaryProbe.probe(
            command: "/nonexistent/path/to/binary",
            pluginDirectory: pluginDir,
            fileManager: fm
        )
        #expect(result == .notFound)
    }

    @Test("probe returns .notExecutable for file without +x")
    func testNotExecutable() throws {
        let fm = InMemoryFileManager()
        let pluginDir = URL(fileURLWithPath: "/test/plugins/test-plugin")
        let filePath = pluginDir.appendingPathComponent("not-executable")
        fm.createFile(atPath: filePath.path, contents: Data("hello".utf8), attributes: [.posixPermissions: 0o644])

        let result = BinaryProbe.probe(
            command: filePath.path,
            pluginDirectory: pluginDir,
            fileManager: fm
        )
        #expect(result == .notExecutable)
    }

    @Test("probe returns .cliTool for a binary that doesn't respond to --piqley-info")
    func testCliTool() {
        // This test needs real filesystem because it runs /bin/echo
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-binary-probe-tests-\(UUID().uuidString)")
        let result = BinaryProbe.probe(
            command: "/bin/echo",
            pluginDirectory: tempDir,
            fileManager: FileManager.default
        )
        #expect(result == .cliTool)
    }

    @Test("resolveExecutable returns absolute path as-is")
    func testResolveExecutableAbsolute() {
        let tempDir = URL(fileURLWithPath: "/test/plugins/test-plugin")
        let path = BinaryProbe.resolveExecutable(
            "/usr/bin/exiftool", pluginDirectory: tempDir
        )
        #expect(path == "/usr/bin/exiftool")
    }

    @Test("resolveExecutable resolves relative path against plugin dir")
    func testResolveExecutableRelative() {
        let tempDir = URL(fileURLWithPath: "/test/plugins/test-plugin")
        let path = BinaryProbe.resolveExecutable(
            "./bin/my-plugin", pluginDirectory: tempDir
        )
        #expect(path == tempDir.appendingPathComponent("./bin/my-plugin").path)
    }
}
