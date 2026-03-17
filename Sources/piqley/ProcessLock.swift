import Foundation

final class ProcessLock {
    private var fileDescriptor: Int32
    private let path: String
    private var released = false

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw ProcessLockError.cannotOpenLockFile(path: path) }
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fd)
            throw ProcessLockError.alreadyRunning
        }
        fileDescriptor = fd
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
}
