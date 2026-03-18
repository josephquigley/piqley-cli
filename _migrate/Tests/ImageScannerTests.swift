import XCTest
@testable import piqley

final class ImageScannerTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testFindsJPEGFiles() throws {
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("a.jpg").path)
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("b.JPEG").path)
        try "not an image".write(to: tmpDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertEqual(files.count, 2)
    }

    func testSortsByDateTaken() throws {
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("newer.jpg").path, dateTimeOriginal: "2026:03:15 10:00:00")
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("older.jpg").path, dateTimeOriginal: "2026:01:01 08:00:00")
        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].path.hasSuffix("older.jpg"))
        XCTAssertTrue(files[1].path.hasSuffix("newer.jpg"))
    }

    func testMissingDateSortsToEnd() throws {
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("dated.jpg").path, dateTimeOriginal: "2026:01:01 08:00:00")
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("undated.jpg").path, dateTimeOriginal: nil)
        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].path.hasSuffix("dated.jpg"))
        XCTAssertTrue(files[1].path.hasSuffix("undated.jpg"))
    }

    func testEmptyFolder() throws {
        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertTrue(files.isEmpty)
    }
}
