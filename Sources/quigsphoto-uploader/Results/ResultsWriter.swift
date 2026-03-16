import Foundation

struct ProcessingResults {
    var successes: [String] = []
    var failures: [String] = []
    var duplicates: [String] = []
    var drafts: [String] = []
    var scheduled: [String] = []
}

struct JSONResults: Codable {
    let failures: [String]
    let duplicates: [String]
    let successes: [String]
}

enum ResultsWriter {
    static func writeText(results: ProcessingResults, to directory: String, verbose: Bool) throws {
        if !results.failures.isEmpty {
            let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-failure.txt")
            try results.failures.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if !results.duplicates.isEmpty {
            let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-duplicate.txt")
            try results.duplicates.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if verbose && !results.successes.isEmpty {
            let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-success.txt")
            try results.successes.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func writeJSON(results: ProcessingResults, to directory: String, verbose: Bool) throws {
        let jsonResults = JSONResults(
            failures: results.failures,
            duplicates: results.duplicates,
            successes: verbose ? results.successes : []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(jsonResults)
        let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-results.json")
        try data.write(to: URL(fileURLWithPath: path))
    }
}
