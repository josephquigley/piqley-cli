import Foundation

/// A runtime error that prints its message to stderr and exits with code 1,
/// without appending ArgumentParser usage text.
struct CleanError: Error, CustomStringConvertible {
    let description: String

    init(_ message: String) {
        description = message
    }
}
