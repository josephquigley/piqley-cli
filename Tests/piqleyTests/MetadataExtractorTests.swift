#if canImport(ImageIO)
import Testing
import Foundation
@testable import piqley

@Suite("MetadataExtractor")
struct MetadataExtractorTests {
    @Test("extracts IPTC keywords from test JPEG")
    func testIPTCKeywords() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(
            at: imgPath,
            keywords: ["Nashville", "Sunset"]
        )

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        let keywords = result["IPTC:Keywords"]
        #expect(keywords == .array([.string("Nashville"), .string("Sunset")]))
    }

    @Test("extracts EXIF DateTimeOriginal")
    func testEXIFDate() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath, dateTimeOriginal: "2026:03:15 18:42:00")

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        #expect(result["EXIF:DateTimeOriginal"] == .string("2026:03:15 18:42:00"))
    }

    @Test("extracts TIFF camera make and model")
    func testTIFFCamera() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath, cameraMake: "Canon", cameraModel: "EOS R5")

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        #expect(result["TIFF:Make"] == .string("Canon"))
        #expect(result["TIFF:Model"] == .string("EOS R5"))
    }

    @Test("does not crash for image with minimal metadata")
    func testMinimalMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath, dateTimeOriginal: nil)

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        // Should return a valid dictionary without crashing
        #expect(result.count >= 0)
    }

    @Test("returns empty dict for nonexistent file")
    func testNonexistentFile() {
        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: "/nonexistent/image.jpg"))
        #expect(result.isEmpty)
    }
}
#endif
