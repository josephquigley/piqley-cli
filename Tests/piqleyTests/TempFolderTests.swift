import Testing
import Foundation
@testable import piqley

@Suite("TempFolder")
struct TempFolderTests {
    @Test("creates a unique temp directory under /tmp")
    func testCreate() throws {
        let temp = try TempFolder.create()
        defer { try? temp.delete() }
        #expect(FileManager.default.fileExists(atPath: temp.url.path))
        #expect(temp.url.path.hasPrefix(NSTemporaryDirectory()))
    }

    @Test("delete removes the temp directory")
    func testDelete() throws {
        let temp = try TempFolder.create()
        let path = temp.url.path
        try temp.delete()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("copyImages copies JPEG and JXL files")
    func testCopyImages() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        // Create test files
        try "data".write(to: sourceDir.appendingPathComponent("photo.jpg"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("photo.jpeg"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("raw.jxl"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let temp = try TempFolder.create()
        defer { try? temp.delete() }

        try temp.copyImages(from: sourceDir)

        let copied = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(copied.contains("photo.jpg"))
        #expect(copied.contains("photo.jpeg"))
        #expect(copied.contains("raw.jxl"))
        #expect(!copied.contains("readme.txt"))
    }

    @Test("copyImages skips hidden files")
    func testSkipsHidden() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        try "data".write(to: sourceDir.appendingPathComponent(".hidden.jpg"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("visible.jpg"), atomically: true, encoding: .utf8)

        let temp = try TempFolder.create()
        defer { try? temp.delete() }

        try temp.copyImages(from: sourceDir)
        let copied = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(copied.contains("visible.jpg"))
        #expect(!copied.contains(".hidden.jpg"))
    }

    @Test("two TempFolders have different paths")
    func testUnique() throws {
        let tempA = try TempFolder.create()
        let tempB = try TempFolder.create()
        defer { try? tempA.delete(); try? tempB.delete() }
        #expect(tempA.url.path != tempB.url.path)
    }
}
