import XCTest
import ImageIO
@testable import quigsphoto_uploader

final class ImageSignerTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testSignEmbedsXmpFields() async throws {
        guard GPGImageSigner.isGPGAvailable() else {
            throw XCTSkip("GPG not installed, skipping signing test")
        }
        guard let fingerprint = try? GPGImageSigner.firstAvailableKeyFingerprint() else {
            throw XCTSkip("No GPG secret keys available, skipping signing test")
        }
        guard GPGImageSigner.canSignNonInteractively(keyFingerprint: fingerprint) else {
            throw XCTSkip("GPG key requires interactive passphrase entry, skipping")
        }

        let path = tmpDir.appendingPathComponent("sign-test.jpg").path
        try TestFixtures.createTestJPEG(at: path, cameraMake: "FUJIFILM")

        let signingConfig = AppConfig.SigningConfig(keyFingerprint: fingerprint)
        let signer = GPGImageSigner(config: signingConfig)
        let result = try await signer.sign(imageAt: path)

        XCTAssertFalse(result.contentHash.isEmpty)
        XCTAssertFalse(result.signature.isEmpty)
        XCTAssertEqual(result.keyFingerprint, fingerprint)
        XCTAssertTrue(result.signature.contains("BEGIN PGP SIGNATURE"))

        // Verify XMP was written to the file
        let xmp = try XMPSignatureReader.read(
            from: path,
            namespace: signingConfig.xmpNamespace,
            prefix: signingConfig.xmpPrefix
        )
        XCTAssertNotNil(xmp)
        XCTAssertEqual(xmp?.contentHash, result.contentHash)
        XCTAssertEqual(xmp?.signature, result.signature)
        XCTAssertEqual(xmp?.keyFingerprint, fingerprint)
        XCTAssertEqual(xmp?.algorithm, "GPG-SHA256")
    }

    func testSignPreservesImageDimensions() async throws {
        guard GPGImageSigner.isGPGAvailable() else {
            throw XCTSkip("GPG not installed")
        }
        guard let fingerprint = try? GPGImageSigner.firstAvailableKeyFingerprint() else {
            throw XCTSkip("No GPG secret keys available")
        }
        guard GPGImageSigner.canSignNonInteractively(keyFingerprint: fingerprint) else {
            throw XCTSkip("GPG key requires interactive passphrase entry, skipping")
        }

        let path = tmpDir.appendingPathComponent("preserve-test.jpg").path
        try TestFixtures.createTestJPEG(at: path, width: 500, height: 300, cameraMake: "Canon")

        let sourceBefore = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let propsBefore = CGImageSourceCopyPropertiesAtIndex(sourceBefore, 0, nil) as! [String: Any]
        let widthBefore = propsBefore[kCGImagePropertyPixelWidth as String] as! Int

        let signingConfig = AppConfig.SigningConfig(keyFingerprint: fingerprint)
        let signer = GPGImageSigner(config: signingConfig)
        _ = try await signer.sign(imageAt: path)

        let sourceAfter = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let propsAfter = CGImageSourceCopyPropertiesAtIndex(sourceAfter, 0, nil) as! [String: Any]
        let widthAfter = propsAfter[kCGImagePropertyPixelWidth as String] as! Int

        XCTAssertEqual(widthBefore, widthAfter)
    }

    func testGPGSigningFailsWithBadKey() async throws {
        guard GPGImageSigner.isGPGAvailable() else {
            throw XCTSkip("GPG not installed")
        }

        let path = tmpDir.appendingPathComponent("fail-test.jpg").path
        try TestFixtures.createTestJPEG(at: path)

        let signingConfig = AppConfig.SigningConfig(keyFingerprint: "NONEXISTENT_KEY_000000")
        let signer = GPGImageSigner(config: signingConfig)

        do {
            _ = try await signer.sign(imageAt: path)
            XCTFail("Expected signing to fail with nonexistent key")
        } catch {
            // Expected — GPG should fail with unknown key
        }
    }

    func testXMPSignatureReaderReturnsNilForUnsignedImage() throws {
        let path = tmpDir.appendingPathComponent("unsigned.jpg").path
        try TestFixtures.createTestJPEG(at: path)

        let xmp = try XMPSignatureReader.read(
            from: path,
            namespace: AppConfig.SigningConfig.defaultXmpNamespace,
            prefix: AppConfig.SigningConfig.defaultXmpPrefix
        )
        XCTAssertNil(xmp)
    }
}
