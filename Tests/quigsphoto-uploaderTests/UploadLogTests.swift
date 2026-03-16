import XCTest
@testable import quigsphoto_uploader

final class UploadLogTests: XCTestCase {
    var tmpDir: URL!
    var logPath: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logPath = tmpDir.appendingPathComponent("upload-log.jsonl").path
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testAppendAndContains() throws {
        let log = UploadLog(path: logPath)
        let entry = UploadLogEntry(filename: "IMG_001.jpg", ghostUrl: "https://quigs.photo/p/test", postId: "abc123", timestamp: Date())
        try log.append(entry)
        XCTAssertTrue(try log.contains(filename: "IMG_001.jpg"))
        XCTAssertFalse(try log.contains(filename: "IMG_002.jpg"))
    }
    func testEmptyLogContainsNothing() throws {
        let log = UploadLog(path: logPath)
        XCTAssertFalse(try log.contains(filename: "anything.jpg"))
    }
    func testMultipleAppends() throws {
        let log = UploadLog(path: logPath)
        for i in 1...5 {
            try log.append(UploadLogEntry(filename: "IMG_\(i).jpg", ghostUrl: "https://quigs.photo/p/\(i)", postId: "id\(i)", timestamp: Date()))
        }
        XCTAssertTrue(try log.contains(filename: "IMG_3.jpg"))
        XCTAssertFalse(try log.contains(filename: "IMG_6.jpg"))
    }
}
