import Foundation

final class ProcessLock {
    private var fileDescriptor: Int32
    private let path: String
    private var released = false

    init(path: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fileDesc = open(path, O_CREAT | O_RDWR, 0o644)
        guard fileDesc >= 0 else { throw ProcessLockError.cannotOpenLockFile(path: path) }
        let result = flock(fileDesc, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fileDesc)
            throw ProcessLockError.alreadyRunning
        }
        fileDescriptor = fileDesc
        self.path = path
    }

    static func formatDuration(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        var parts: [String] = []
        if minutes > 0 {
            parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        }
        if remainingSeconds > 0 {
            parts.append("\(remainingSeconds) second\(remainingSeconds == 1 ? "" : "s")")
        }
        return parts.joined(separator: " ")
    }

    func release() {
        guard !released else { return }
        released = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    deinit { release() }
}

enum ProcessLockError: Error, LocalizedError {
    case cannotOpenLockFile(path: String)
    case alreadyRunning
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .cannotOpenLockFile(path): "Cannot open lock file: \(path)"
        case .alreadyRunning: "Another instance of \(AppConstants.name) is already running"
        case let .timedOut(seconds):
            "Timed out after \(ProcessLock.formatDuration(seconds: seconds)) waiting for another instance to finish"
        }
    }

    var failureReason: String? {
        switch self {
        case .cannotOpenLockFile: "The lock file could not be created or opened."
        case .alreadyRunning: "A process lock is already held by another instance."
        case .timedOut: "The lock was not released within the specified timeout."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cannotOpenLockFile: "Check that the parent directory exists and is writable."
        case .alreadyRunning: "Wait for the other instance to finish, or remove the stale lock file if the previous run crashed."
        case .timedOut: "Check if the other instance is still running, or remove the stale lock file if the previous run crashed."
        }
    }
}
