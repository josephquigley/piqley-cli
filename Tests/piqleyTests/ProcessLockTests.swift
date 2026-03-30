import XCTest
@testable import piqley

final class ProcessLockTests: XCTestCase {
    func testAcquireAndReleaseLock() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock = try ProcessLock(path: lockPath)
        lock.release()
    }

    func testDoubleAcquireFails() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock1 = try ProcessLock(path: lockPath)
        XCTAssertThrowsError(try ProcessLock(path: lockPath))
        lock1.release()
    }

    func testFormatDurationMinutesOnly() {
        XCTAssertEqual(ProcessLock.formatDuration(seconds: 600), "10 minutes")
    }

    func testFormatDurationMinutesAndSeconds() {
        XCTAssertEqual(ProcessLock.formatDuration(seconds: 150), "2 minutes 30 seconds")
    }

    func testFormatDurationSecondsOnly() {
        XCTAssertEqual(ProcessLock.formatDuration(seconds: 30), "30 seconds")
    }

    func testFormatDurationOneMinute() {
        XCTAssertEqual(ProcessLock.formatDuration(seconds: 60), "1 minute")
    }

    func testFormatDurationOneSecond() {
        XCTAssertEqual(ProcessLock.formatDuration(seconds: 1), "1 second")
    }

    func testAcquireSucceedsImmediately() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock = try await ProcessLock.acquire(path: lockPath, timeout: 10)
        lock.release()
    }

    func testAcquireTimesOut() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let holder = try ProcessLock(path: lockPath)
        defer { holder.release() }

        do {
            _ = try await ProcessLock.acquire(path: lockPath, timeout: 1)
            XCTFail("Expected timedOut error")
        } catch ProcessLockError.timedOut {
            // expected
        }
    }
}
