import Foundation
import PiqleyCore

protocol TagMatcher: Sendable {
    func matches(_ value: String) -> Bool
    func replacing(_ value: String, with replacement: String) -> String
    var patternDescription: String { get }
}

extension TagMatcher {
    func replacing(_ value: String, with replacement: String) -> String {
        matches(value) ? replacement : value
    }
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

    func replacing(_ value: String, with replacement: String) -> String {
        guard let match = value.wholeMatch(of: regex) else { return value }
        var result = replacement
        for groupIndex in 1 ..< match.output.count {
            if let capture = match.output[groupIndex].substring {
                result = result.replacingOccurrences(of: "$\(groupIndex)", with: String(capture))
            }
        }
        return result
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
