import Foundation

struct EmailLogEntry: Codable {
    let filename: String
    let emailTo: String
    let subject: String
    let timestamp: Date
}

struct EmailLog {
    let path: String
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    func contains(filename: String) throws -> Bool {
        guard fileExists else { return false }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(EmailLogEntry.self, from: lineData) else { continue }
            if entry.filename == filename { return true }
        }
        return false
    }

    func append(_ entry: EmailLogEntry) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(contentsOf: "\n".utf8)
        let fileDesc = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fileDesc >= 0 else { throw EmailLogError.cannotOpenFile(path: path) }
        defer { close(fileDesc) }
        data.withUnsafeBytes { buffer in _ = write(fileDesc, buffer.baseAddress!, buffer.count) }
    }
}

enum EmailLogError: Error, LocalizedError {
    case cannotOpenFile(path: String)
    var errorDescription: String? {
        switch self { case let .cannotOpenFile(path): "Cannot open email log: \(path)" }
    }

    var failureReason: String? {
        switch self { case .cannotOpenFile: "The email log file could not be opened or created." }
    }

    var recoverySuggestion: String? {
        switch self { case .cannotOpenFile: "Check that the log directory exists and is writable." }
    }
}
