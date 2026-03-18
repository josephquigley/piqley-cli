import Foundation

enum ExitCodeResult: Equatable, Sendable {
    case success
    case warning
    case critical
}

struct ExitCodeEvaluator: Sendable {
    private let successCodes: [Int32]
    private let warningCodes: [Int32]
    private let criticalCodes: [Int32]
    private let useUnixDefaults: Bool

    init(successCodes: [Int32]?, warningCodes: [Int32]?, criticalCodes: [Int32]?) {
        let success = successCodes ?? []
        let warning = warningCodes ?? []
        let critical = criticalCodes ?? []
        self.successCodes = success
        self.warningCodes = warning
        self.criticalCodes = critical
        // If all arrays are empty (or nil), fall back to Unix defaults
        useUnixDefaults = success.isEmpty && warning.isEmpty && critical.isEmpty
    }

    func evaluate(_ code: Int32) -> ExitCodeResult {
        if useUnixDefaults {
            return code == 0 ? .success : .critical
        }
        if !successCodes.isEmpty, successCodes.contains(code) { return .success }
        if !warningCodes.isEmpty, warningCodes.contains(code) { return .warning }
        if !criticalCodes.isEmpty, criticalCodes.contains(code) { return .critical }
        // Not in any defined list — default to critical
        return .critical
    }
}
