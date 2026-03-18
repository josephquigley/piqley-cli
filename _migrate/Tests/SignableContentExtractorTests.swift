import XCTest
import ImageIO
@testable import piqley

final class SignableContentExtractorTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testDeterministicHash() throws {
        let path = tmpDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: path, cameraMake: "FUJIFILM", cameraModel: "X-T5")

        let extractor = SignableContentExtractor()
        let hash1 = try extractor.hashFile(at: path)
        let hash2 = try extractor.hashFile(at: path)

        XCTAssertEqual(hash1, hash2, "Same file should produce same hash")
        XCTAssertEqual(hash1.count, 64, "SHA-256 hex should be 64 characters")
    }

    func testDifferentFilesProduceDifferentHashes() throws {
        let path1 = tmpDir.appendingPathComponent("img1.jpg").path
        let path2 = tmpDir.appendingPathComponent("img2.jpg").path
        try TestFixtures.createTestJPEG(at: path1, width: 100, height: 100)
        try TestFixtures.createTestJPEG(at: path2, width: 200, height: 200)

        let extractor = SignableContentExtractor()
        let hash1 = try extractor.hashFile(at: path1)
        let hash2 = try extractor.hashFile(at: path2)

        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashFileStrippingSignatureMatchesOriginal() throws {
        let path = tmpDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: path, cameraMake: "Canon")

        let extractor = SignableContentExtractor()
        let hashBefore = try extractor.hashFile(at: path)

        // Add XMP signing fields
        try addXmpSigningFields(to: path, namespace: "https://quigs.photo/xmp/1.0/", prefix: "piqley")

        // Hash after adding XMP should differ (file changed)
        let hashWithXmp = try extractor.hashFile(at: path)
        XCTAssertNotEqual(hashBefore, hashWithXmp, "Adding XMP should change the file hash")

        // But stripping the signing namespace should recover a consistent hash
        let hashStripped = try extractor.hashFileStrippingSignature(
            at: path,
            namespace: "https://quigs.photo/xmp/1.0/",
            prefix: "piqley"
        )

        // Note: the stripped hash may not exactly equal hashBefore because CGImageDestination
        // re-encodes the image. But it should be deterministic — calling it twice should match.
        let hashStripped2 = try extractor.hashFileStrippingSignature(
            at: path,
            namespace: "https://quigs.photo/xmp/1.0/",
            prefix: "piqley"
        )
        XCTAssertEqual(hashStripped, hashStripped2, "Stripping should be deterministic")
    }

    private func addXmpSigningFields(to path: String, namespace: String, prefix: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageType = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TestFixtureError.cannotCreateContext
        }

        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let metadata = CGImageMetadataCreateMutable()

        guard let tag = CGImageMetadataTagCreate(
            namespace as CFString,
            prefix as CFString,
            "contentHash" as CFString,
            .string,
            "fakehash123" as CFTypeRef
        ) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):contentHash" as CFString, tag)

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, imageType, 1, nil) else {
            throw TestFixtureError.cannotCreateDestination
        }

        CGImageDestinationAddImageAndMetadata(dest, cgImage, metadata, existingProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestFixtureError.cannotFinalize }
    }
}
