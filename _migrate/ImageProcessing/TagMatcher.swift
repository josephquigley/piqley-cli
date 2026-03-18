import Foundation

protocol TagMatcher {
    func matches(_ keyword: String) -> Bool
    var description: String { get }
}

struct ExactMatcher: TagMatcher {
    let pattern: String

    var description: String { "exact: \(pattern)" }

    func matches(_ keyword: String) -> Bool {
        keyword.lowercased() == pattern.lowercased()
    }
}

struct GlobMatcher: TagMatcher {
    let pattern: String

    var description: String { "glob: \(pattern)" }

    func matches(_ keyword: String) -> Bool {
        fnmatch(pattern.lowercased(), keyword.lowercased(), 0) == 0
    }
}

struct RegexMatcher: TagMatcher {
    let regex: Regex<AnyRegexOutput>
    let pattern: String

    var description: String { "regex: \(pattern)" }

    init(pattern: String) throws {
        self.pattern = pattern
        regex = try Regex(pattern).ignoresCase()
    }

    func matches(_ keyword: String) -> Bool {
        keyword.wholeMatch(of: regex) != nil
    }
}

struct KeywordFilterResult {
    let kept: [String]
    let blocked: [(keyword: String, matcher: String)]
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
    static func buildMatchers(from patterns: [String]) throws -> [TagMatcher] {
        try patterns.map { entry in
            if entry.hasPrefix("regex:") {
                let pattern = String(entry.dropFirst(6))
                do {
                    return try RegexMatcher(pattern: pattern)
                } catch {
                    throw TagMatcherError.invalidRegex(pattern: pattern, underlying: error)
                }
            } else if entry.hasPrefix("glob:") {
                let pattern = String(entry.dropFirst(5))
                return GlobMatcher(pattern: pattern)
            } else {
                return ExactMatcher(pattern: entry)
            }
        }
    }
}
