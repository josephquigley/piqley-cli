import XCTest
@testable import piqley

final class GhostDeduplicatorTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testCacheHitReturnsDuplicate() throws {
        let logPath = tmpDir.appendingPathComponent("upload-log.jsonl").path
        let log = UploadLog(path: logPath)
        try log.append(UploadLogEntry(filename: "IMG_001.jpg", ghostUrl: "https://quigs.photo/p/test", postId: "abc", timestamp: Date()))
        let dedup = GhostDeduplicator(uploadLog: log, client: nil)
        XCTAssertTrue(try dedup.checkCacheOnly(filename: "IMG_001.jpg"))
    }

    func testCacheMissReturnsNotDuplicate() throws {
        let logPath = tmpDir.appendingPathComponent("upload-log.jsonl").path
        let log = UploadLog(path: logPath)
        let dedup = GhostDeduplicator(uploadLog: log, client: nil)
        XCTAssertFalse(try dedup.checkCacheOnly(filename: "IMG_999.jpg"))
    }
}
