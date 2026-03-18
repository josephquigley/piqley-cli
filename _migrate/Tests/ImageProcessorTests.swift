import XCTest
import ImageIO
@testable import piqley

final class ImageProcessorTests: XCTestCase {
    var tmpDir: URL!
    let defaultAllowlist = AppConfig.ProcessingConfig.defaultMetadataAllowlist

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testResizeLandscapeImage() throws {
        let inputPath = tmpDir.appendingPathComponent("input.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, width: 4000, height: 3000)
        let processor = CoreGraphicsImageProcessor()
        try processor.process(inputPath: inputPath, outputPath: outputPath, maxLongEdge: 2000, jpegQuality: 80, metadataAllowlist: defaultAllowlist)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let width = props[kCGImagePropertyPixelWidth as String] as! Int
        let height = props[kCGImagePropertyPixelHeight as String] as! Int
        XCTAssertEqual(width, 2000)
        XCTAssertEqual(height, 1500)
    }

    func testNoUpscale() throws {
        let inputPath = tmpDir.appendingPathComponent("small.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, width: 800, height: 600)
        let processor = CoreGraphicsImageProcessor()
        try processor.process(inputPath: inputPath, outputPath: outputPath, maxLongEdge: 2000, jpegQuality: 80, metadataAllowlist: defaultAllowlist)

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let width = props[kCGImagePropertyPixelWidth as String] as! Int
        XCTAssertEqual(width, 800)
    }

    func testGPSStripped() throws {
        let inputPath = tmpDir.appendingPathComponent("gps.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, title: "Keep This Title", gps: true)
        let processor = CoreGraphicsImageProcessor()
        try processor.process(inputPath: inputPath, outputPath: outputPath, maxLongEdge: 2000, jpegQuality: 80, metadataAllowlist: defaultAllowlist)

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
    }

    func testAllowlistKeepsOnlyAllowedTags() throws {
        let inputPath = tmpDir.appendingPathComponent("meta.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(
            at: inputPath,
            title: "Test Title",
            dateTimeOriginal: "2026:01:15 10:30:00",
            cameraMake: "FUJIFILM",
            cameraModel: "X-T5",
            lensModel: "XF35mmF1.4 R",
            gps: true
        )
        let processor = CoreGraphicsImageProcessor()
        try processor.process(
            inputPath: inputPath,
            outputPath: outputPath,
            maxLongEdge: 2000,
            jpegQuality: 80,
            metadataAllowlist: ["TIFF.Make", "EXIF.DateTimeOriginal"]
        )

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]

        // Allowed tags are present
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?["Make"] as? String, "FUJIFILM")

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:01:15 10:30:00")

        // Non-allowed tags are stripped
        XCTAssertNil(tiff?["Model"])
        XCTAssertNil(exif?[kCGImagePropertyExifLensModel as String])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary as String])
    }

    func testEmptyAllowlistStripsAllMetadata() throws {
        let inputPath = tmpDir.appendingPathComponent("strip.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(
            at: inputPath,
            title: "Should Be Gone",
            cameraMake: "Canon",
            cameraModel: "EOS R5"
        )
        let processor = CoreGraphicsImageProcessor()
        try processor.process(
            inputPath: inputPath,
            outputPath: outputPath,
            maxLongEdge: 2000,
            jpegQuality: 80,
            metadataAllowlist: []
        )

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]

        // CoreGraphics auto-adds ColorSpace/PixelDimensions to EXIF, but no user metadata should remain
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let autoKeys: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension"]
        let userKeys = Set(exif.keys).subtracting(autoKeys)
        XCTAssertTrue(userKeys.isEmpty, "Expected no user EXIF keys, found: \(userKeys)")
        XCTAssertNil(props[kCGImagePropertyTIFFDictionary as String])
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary as String])
    }
}
