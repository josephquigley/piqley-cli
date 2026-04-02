import Foundation

// MARK: - Concurrency Helpers

/// Tracks the timestamp of last activity for inactivity-based timeouts.
actor ActivityTracker {
    private var lastActivity: Date = .init()

    func touch() {
        lastActivity = Date()
    }

    func secondsSinceLastActivity() -> Double {
        Date().timeIntervalSince(lastActivity)
    }
}

/// Returns an `AsyncStream` of lines read from a pipe's file handle using
/// `readabilityHandler`, which delivers data as soon as the OS makes it
/// available — unlike `FileHandle.bytes.lines` which may buffer until EOF.
func pipeLines(_ fileHandle: FileHandle) -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream.makeStream(of: String.self)
    let buffer = PipeLineBuffer()
    fileHandle.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            // EOF
            if let remaining = buffer.flush() {
                continuation.yield(remaining)
            }
            continuation.finish()
            handle.readabilityHandler = nil
            return
        }
        for line in buffer.append(data) {
            continuation.yield(line)
        }
    }
    return stream
}

/// Accumulates pipe data and splits on newlines. Thread-safe because
/// `readabilityHandler` callbacks are serialized by the dispatch source.
private final class PipeLineBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ newData: Data) -> [String] {
        data.append(newData)
        var lines: [String] = []
        while let idx = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[data.startIndex ..< idx]
            data = Data(data[data.index(after: idx)...])
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    func flush() -> String? {
        guard !data.isEmpty else { return nil }
        let remaining = String(data: data, encoding: .utf8)
        data = Data()
        return remaining
    }
}
