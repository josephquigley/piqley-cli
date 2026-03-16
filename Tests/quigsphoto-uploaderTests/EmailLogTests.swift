import XCTest
@testable import quigsphoto_uploader

final class EmailLogTests: XCTestCase {
    var tmpDir: URL!
    var logPath: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logPath = tmpDir.appendingPathComponent("email-log.jsonl").path
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testAppendAndContains() throws {
        let log = EmailLog(path: logPath)
        let entry = EmailLogEntry(filename: "IMG_001.jpg", emailTo: "user@365project.example", subject: "Test Photo", timestamp: Date())
        try log.append(entry)
        XCTAssertTrue(try log.contains(filename: "IMG_001.jpg"))
        XCTAssertFalse(try log.contains(filename: "IMG_002.jpg"))
    }
    func testNonExistentLogReturnsFalse() throws {
        let log = EmailLog(path: logPath)
        XCTAssertFalse(try log.contains(filename: "anything.jpg"))
    }
    func testFileExistsProperty() throws {
        let log = EmailLog(path: logPath)
        XCTAssertFalse(log.fileExists)
        try log.append(EmailLogEntry(filename: "IMG_001.jpg", emailTo: "user@test.com", subject: "Test", timestamp: Date()))
        XCTAssertTrue(log.fileExists)
    }
}
