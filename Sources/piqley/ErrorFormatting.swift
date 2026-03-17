import Foundation

/// Formats any error with its full LocalizedError details in a consistent format.
/// Includes failure reason and recovery suggestion when available.
func formatError(_ error: any Error) -> String {
    var parts = [error.localizedDescription]

    if let localized = error as? LocalizedError {
        if let reason = localized.failureReason {
            parts.append("Reason: \(reason)")
        }
        if let recovery = localized.recoverySuggestion {
            parts.append("Suggestion: \(recovery)")
        }
    }

    return parts.joined(separator: "\n  ")
}
