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
    var errorDescription: String? {
        switch self {
        case let .cannotOpenLockFile(path): "Cannot open lock file: \(path)"
        case .alreadyRunning: "Another instance of \(AppConstants.name) is already running"
        }
    }

    var failureReason: String? {
        switch self {
        case .cannotOpenLockFile: "The lock file could not be created or opened."
        case .alreadyRunning: "A process lock is already held by another instance."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cannotOpenLockFile: "Check that the parent directory exists and is writable."
        case .alreadyRunning: "Wait for the other instance to finish, or remove the stale lock file if the previous run crashed."
        }
    }
}
