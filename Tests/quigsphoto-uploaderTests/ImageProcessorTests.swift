import XCTest
import ImageIO
@testable import quigsphoto_uploader

final class ImageProcessorTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testResizeLandscapeImage() throws {
        let inputPath = tmpDir.appendingPathComponent("input.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, width: 4000, height: 3000)
        let processor = CoreGraphicsImageProcessor()
        try processor.process(inputPath: inputPath, outputPath: outputPath, maxLongEdge: 2000, jpegQuality: 80)

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
        try processor.process(inputPath: inputPath, outputPath: outputPath, maxLongEdge: 2000, jpegQuality: 80)

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let width = props[kCGImagePropertyPixelWidth as String] as! Int
        XCTAssertEqual(width, 800)
    }

    func testGPSStripped() throws {
        let inputPath = tmpDir.appendingPathComponent("gps.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, title: "Keep This Title")
        let processor = CoreGraphicsImageProcessor()
        try processor.process(inputPath: inputPath, outputPath: outputPath, maxLongEdge: 2000, jpegQuality: 80)

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
    }
}
