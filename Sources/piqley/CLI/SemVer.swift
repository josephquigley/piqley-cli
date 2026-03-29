import Foundation

struct SemVer: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    var versionString: String { "\(major).\(minor).\(patch)" }

    static func parse(_ string: String) throws -> SemVer {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else {
            throw SemVerError.invalidFormat(string)
        }
        return SemVer(major: major, minor: minor, patch: patch)
    }

    /// Determines if `other` is compatible with `self` per semver rules.
    /// For major >= 1: same major. For major 0: same major AND minor.
    func isCompatible(with other: SemVer) -> Bool {
        major == other.major
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum SemVerError: Error, LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case let .invalidFormat(input): "Invalid semver: '\(input)'"
        }
    }
}
