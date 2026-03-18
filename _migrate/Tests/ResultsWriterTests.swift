import XCTest
@testable import piqley

final class ResultsWriterTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testWriteTextFiles() throws {
        let results = ProcessingResults(successes: ["a.jpg", "b.jpg"], failures: ["c.jpg"], duplicates: ["d.jpg"])
        try ResultsWriter.writeText(results: results, to: tmpDir.path, verbose: false)
        let failurePath = tmpDir.appendingPathComponent("\(AppConstants.resultFilePrefix)-failure.txt").path
        let dupPath = tmpDir.appendingPathComponent("\(AppConstants.resultFilePrefix)-duplicate.txt").path
        let successPath = tmpDir.appendingPathComponent("\(AppConstants.resultFilePrefix)-success.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: failurePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dupPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: successPath))
        let failureContent = try String(contentsOfFile: failurePath, encoding: .utf8)
        XCTAssertEqual(failureContent.trimmingCharacters(in: .whitespacesAndNewlines), "c.jpg")
    }

    func testWriteTextFilesVerbose() throws {
        let results = ProcessingResults(successes: ["a.jpg"], failures: [], duplicates: [])
        try ResultsWriter.writeText(results: results, to: tmpDir.path, verbose: true)
        let successPath = tmpDir.appendingPathComponent("\(AppConstants.resultFilePrefix)-success.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: successPath))
    }

    func testEmptyArraysProduceNoFiles() throws {
        let results = ProcessingResults(successes: [], failures: [], duplicates: [])
        try ResultsWriter.writeText(results: results, to: tmpDir.path, verbose: false)
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testWriteJSON() throws {
        let results = ProcessingResults(successes: ["a.jpg"], failures: ["b.jpg"], duplicates: ["c.jpg"])
        try ResultsWriter.writeJSON(results: results, to: tmpDir.path, verbose: true)
        let jsonPath = tmpDir.appendingPathComponent("\(AppConstants.resultFilePrefix)-results.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoded = try JSONDecoder().decode(JSONResults.self, from: data)
        XCTAssertEqual(decoded.failures, ["b.jpg"])
        XCTAssertEqual(decoded.duplicates, ["c.jpg"])
        XCTAssertEqual(decoded.successes, ["a.jpg"])
    }

    func testWriteJSONNonVerboseOmitsSuccesses() throws {
        let results = ProcessingResults(successes: ["a.jpg"], failures: [], duplicates: [])
        try ResultsWriter.writeJSON(results: results, to: tmpDir.path, verbose: false)
        let jsonPath = tmpDir.appendingPathComponent("\(AppConstants.resultFilePrefix)-results.json").path
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoded = try JSONDecoder().decode(JSONResults.self, from: data)
        XCTAssertTrue(decoded.successes.isEmpty)
    }
}
