import Foundation

protocol TagMatcher: Sendable {
    func matches(_ value: String) -> Bool
    var patternDescription: String { get }
}

struct ExactMatcher: TagMatcher {
    let pattern: String

    var patternDescription: String { "exact: \(pattern)" }

    func matches(_ value: String) -> Bool {
        value.lowercased() == pattern.lowercased()
    }
}

struct GlobMatcher: TagMatcher {
    let pattern: String

    var patternDescription: String { "glob: \(pattern)" }

    func matches(_ value: String) -> Bool {
        fnmatch(pattern.lowercased(), value.lowercased(), 0) == 0
    }
}

struct RegexMatcher: TagMatcher, @unchecked Sendable {
    let regex: Regex<AnyRegexOutput>
    let pattern: String

    var patternDescription: String { "regex: \(pattern)" }

    init(pattern: String) throws {
        self.pattern = pattern
        regex = try Regex(pattern).ignoresCase()
    }

    func matches(_ value: String) -> Bool {
        value.wholeMatch(of: regex) != nil
    }
}

enum TagMatcherError: Error, LocalizedError {
    case invalidRegex(pattern: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .invalidRegex(pattern, _):
            "Invalid regex pattern '\(pattern)'"
        }
    }

    var failureReason: String? {
        switch self {
        case let .invalidRegex(_, underlying):
            underlying.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidRegex:
            "Check the regex syntax in your tag matching configuration."
        }
    }
}

enum TagMatcherFactory {
    static func build(from entry: String) throws -> any TagMatcher {
        if entry.hasPrefix(PatternPrefix.regex) {
            let pattern = String(entry.dropFirst(PatternPrefix.regex.count))
            do {
                return try RegexMatcher(pattern: pattern)
            } catch {
                throw TagMatcherError.invalidRegex(pattern: pattern, underlying: error)
            }
        } else if entry.hasPrefix(PatternPrefix.glob) {
            let pattern = String(entry.dropFirst(PatternPrefix.glob.count))
            return GlobMatcher(pattern: pattern)
        } else {
            return ExactMatcher(pattern: entry)
        }
    }
}
