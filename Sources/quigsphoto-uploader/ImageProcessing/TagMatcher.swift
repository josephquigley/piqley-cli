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
        self.regex = try Regex(pattern).ignoresCase()
    }

    func matches(_ keyword: String) -> Bool {
        keyword.wholeMatch(of: regex) != nil
    }
}

struct KeywordFilterResult {
    let kept: [String]
    let blocked: [(keyword: String, matcher: String)]
}

enum TagMatcherError: Error, CustomStringConvertible {
    case invalidRegex(pattern: String, underlying: Error)

    var description: String {
        switch self {
        case .invalidRegex(let pattern, let underlying):
            return "Invalid regex pattern '\(pattern)': \(underlying.localizedDescription)"
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
