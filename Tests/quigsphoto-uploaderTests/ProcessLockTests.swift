import XCTest
@testable import quigsphoto_uploader

final class ProcessLockTests: XCTestCase {
    func testAcquireAndReleaseLock() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock = try ProcessLock(path: lockPath)
        lock.release()
    }

    func testDoubleAcquireFails() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock1 = try ProcessLock(path: lockPath)
        XCTAssertThrowsError(try ProcessLock(path: lockPath))
        lock1.release()
    }
}
