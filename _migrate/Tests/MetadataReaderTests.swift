import XCTest
@testable import piqley

final class MetadataReaderTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testReadMetadataWithAllFields() throws {
        let path = tmpDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: path, title: "Sunset at the Beach",
            description: "A beautiful sunset", keywords: ["Landscape", "365 Project", "Nature"],
            dateTimeOriginal: "2026:01:15 10:30:00")
        let reader = CGImageMetadataReader()
        let metadata = try reader.read(from: path)
        XCTAssertEqual(metadata.title, "Sunset at the Beach")
        XCTAssertEqual(metadata.description, "A beautiful sunset")
        XCTAssertTrue(metadata.keywords.contains("365 Project"))
        XCTAssertTrue(metadata.keywords.contains("Landscape"))
        XCTAssertNotNil(metadata.dateTimeOriginal)
    }

    func testReadMetadataMissingTitle() throws {
        let path = tmpDir.appendingPathComponent("notitle.jpg").path
        try TestFixtures.createTestJPEG(at: path, title: nil, description: nil, keywords: nil)
        let reader = CGImageMetadataReader()
        let metadata = try reader.read(from: path)
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.description)
    }

    func testLeafKeywordExtraction() {
        XCTAssertEqual(ImageMetadata.leafKeyword("Location > USA > Nashville"), "Nashville")
        XCTAssertEqual(ImageMetadata.leafKeyword("SimpleTag"), "SimpleTag")
        XCTAssertEqual(ImageMetadata.leafKeyword("A > B"), "B")
    }

    func testProcessKeywordsWithBlocklist() {
        let raw = ["Location > USA > Nashville", "365 Project", "WIP", "Nature"]
        let blocklist: [TagMatcher] = [ExactMatcher(pattern: "WIP")]
        let result = ImageMetadata.processKeywords(raw, blocklist: blocklist)
        XCTAssertEqual(result, ["Nashville", "365 Project", "Nature"])
    }

    func testIs365Project() throws {
        let path = tmpDir.appendingPathComponent("365.jpg").path
        try TestFixtures.createTestJPEG(at: path, keywords: ["365 Project", "Nature"])
        let reader = CGImageMetadataReader()
        let metadata = try reader.read(from: path)
        XCTAssertTrue(metadata.is365Project(keyword: "365 Project"))
    }
}
