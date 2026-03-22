import Foundation

enum SDKVersionResolver {
    /// Parse semver tags from `git ls-remote --tags` output.
    static func parseTags(from output: String) -> [SemVer] {
        output.split(separator: "\n").compactMap { line in
            let ref = line.split(separator: "\t").last.map(String.init) ?? ""
            // Skip peeled refs (annotated tag derefs)
            guard !ref.hasSuffix("^{}") else { return nil }
            let tagName = ref.replacingOccurrences(of: "refs/tags/", with: "")
            return try? SemVer.parse(tagName)
        }
    }

    /// Select the highest tag compatible with the CLI version.
    static func bestMatch(for cliVersion: SemVer, from tags: [SemVer]) -> SemVer? {
        tags.filter { cliVersion.isCompatible(with: $0) }.max()
    }

    /// Resolve the best SDK version by querying a git remote.
    static func resolve(cliVersion: SemVer, repoURL: String) throws -> SemVer {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-remote", "--tags", repoURL]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CreateError.gitLsRemoteFailed(repoURL, process.terminationStatus)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let tags = parseTags(from: output)

        guard let best = bestMatch(for: cliVersion, from: tags) else {
            throw CreateError.noCompatibleVersion(cliVersion.versionString, repoURL)
        }

        return best
    }
}

enum CreateError: Error, LocalizedError {
    case gitLsRemoteFailed(String, Int32)
    case noCompatibleVersion(String, String)
    case tarballDownloadFailed(String)
    case extractionFailed(String)
    case templateNotFound(String, String)
    case targetNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case let .gitLsRemoteFailed(url, code):
            "git ls-remote failed for '\(url)' (exit code \(code))"
        case let .noCompatibleVersion(version, url):
            "No SDK release compatible with CLI version \(version) found at '\(url)'"
        case let .tarballDownloadFailed(url):
            "Failed to download tarball from '\(url)'"
        case let .extractionFailed(detail):
            "Failed to extract tarball: \(detail)"
        case let .templateNotFound(language, version):
            "Template for language '\(language)' not found in SDK release \(version)"
        case let .targetNotEmpty(path):
            "Target directory '\(path)' already exists and is not empty"
        }
    }
}
