import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("TempFolder")
struct TempFolderTests {
    @Test("creates a unique temp directory under /tmp")
    func testCreate() throws {
        let fm = InMemoryFileManager()
        let temp = try TempFolder.create(fileManager: fm)
        #expect(fm.fileExists(atPath: temp.url.path))
        #expect(temp.url.path.hasPrefix(fm.temporaryDirectory.path))
    }

    @Test("delete removes the temp directory")
    func testDelete() throws {
        let fm = InMemoryFileManager()
        let temp = try TempFolder.create(fileManager: fm)
        let path = temp.url.path
        try temp.delete()
        #expect(!fm.fileExists(atPath: path))
    }

    @Test("copyImages copies JPEG and JXL files")
    func testCopyImages() throws {
        let fm = InMemoryFileManager()
        let sourceDir = URL(fileURLWithPath: "/test/source")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // Create test files
        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("photo.jpg"))
        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("photo.jpeg"))
        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("raw.jxl"))
        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("readme.txt"))

        let temp = try TempFolder.create(fileManager: fm)

        let result = try temp.copyImages(from: sourceDir)

        let copied = try fm.contentsOfDirectory(atPath: temp.url.path)
        #expect(copied.contains("photo.jpg"))
        #expect(copied.contains("photo.jpeg"))
        #expect(copied.contains("raw.jxl"))
        #expect(!copied.contains("readme.txt"))
        #expect(result.copiedCount == 3)
        #expect(result.skippedFiles == ["readme.txt"])
    }

    @Test("copyImages skips hidden files")
    func testSkipsHidden() throws {
        let fm = InMemoryFileManager()
        let sourceDir = URL(fileURLWithPath: "/test/source")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent(".hidden.jpg"))
        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("visible.jpg"))

        let temp = try TempFolder.create(fileManager: fm)

        let result = try temp.copyImages(from: sourceDir)
        let copied = try fm.contentsOfDirectory(atPath: temp.url.path)
        #expect(copied.contains("visible.jpg"))
        #expect(!copied.contains(".hidden.jpg"))
        #expect(result.copiedCount == 1)
        #expect(result.skippedFiles.isEmpty)
    }

    @Test("copyImages returns skipped files for unsupported formats")
    func testCopyImagesReturnsSkippedFiles() throws {
        let fm = InMemoryFileManager()
        let sourceDir = URL(fileURLWithPath: "/test/source")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("photo.jpg"))
        try fm.write(Data("data".utf8), to: sourceDir.appendingPathComponent("raw.cr3"))

        let temp = try TempFolder.create(fileManager: fm)

        let result = try temp.copyImages(from: sourceDir)
        #expect(result.copiedCount == 1)
        #expect(result.skippedFiles == ["raw.cr3"])
    }

    @Test("two TempFolders have different paths")
    func testUnique() throws {
        let fm = InMemoryFileManager()
        let tempA = try TempFolder.create(fileManager: fm)
        let tempB = try TempFolder.create(fileManager: fm)
        #expect(tempA.url.path != tempB.url.path)
    }
}
