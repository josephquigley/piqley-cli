import Foundation
import PiqleyCore

enum PluginFetchError: Error, CustomStringConvertible {
    case downloadFailed(url: String, httpCode: String)
    case invalidURL(String)
    case cloneFailed(url: String)
    case packageFailed

    var description: String {
        switch self {
        case let .downloadFailed(url, httpCode):
            "Failed to download plugin from \(url) (HTTP \(httpCode))."
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        case let .cloneFailed(url):
            "Failed to clone repository: \(url)"
        case .packageFailed:
            "Failed to package cloned repository into a .piqleyplugin archive."
        }
    }
}

enum PluginSourceKind {
    case file
    case url
    case gitRepo
}

enum PluginFetcher {
    /// Classifies the plugin source string.
    static func sourceKind(_ string: String) -> PluginSourceKind {
        if isGitRepo(string) { return .gitRepo }
        if isURL(string) { return .url }
        return .file
    }

    /// Returns `true` when the string looks like a remote URL (http:// or https://)
    /// that is NOT a git repo.
    static func isURL(_ string: String) -> Bool {
        (string.hasPrefix("http://") || string.hasPrefix("https://")) && !isGitRepo(string)
    }

    /// Returns `true` when the string looks like a git repository URL.
    /// Matches SSH (`git@host:user/repo.git`), `ssh://`, and HTTPS URLs ending in `.git`.
    static func isGitRepo(_ string: String) -> Bool {
        if string.hasPrefix("git@") || string.hasPrefix("ssh://") {
            return true
        }
        if string.hasPrefix("http://") || string.hasPrefix("https://"), string.hasSuffix(".git") {
            return true
        }
        return false
    }

    /// Downloads a `.piqleyplugin` file from a remote URL into a temporary directory.
    /// Returns the local file URL that the caller can pass to the installer/updater.
    /// The caller is responsible for removing the returned file's parent directory.
    static func download(
        from remoteURL: String,
        fileManager: any FileSystemManager = FileManager.default
    ) throws -> (fileURL: URL, tempDir: URL) {
        guard let url = URL(string: remoteURL), url.scheme == "http" || url.scheme == "https" else {
            throw PluginFetchError.invalidURL(remoteURL)
        }

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("piqley-fetch-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Derive a filename from the URL, falling back to a default
        let filename: String
        let lastComponent = url.lastPathComponent
        if lastComponent.hasSuffix(".piqleyplugin") {
            filename = lastComponent
        } else {
            filename = "plugin.piqleyplugin"
        }

        let destFile = tempDir.appendingPathComponent(filename)

        let curl = Process()
        let stdout = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        curl.arguments = [
            "curl", "-sL",
            "-o", destFile.path,
            "-w", "%{http_code}",
            "-A", AppConstants.userAgent,
            remoteURL,
        ]
        curl.standardOutput = stdout
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        curl.waitUntilExit()

        let httpCode = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard curl.terminationStatus == 0,
              httpCode == "200",
              fileManager.fileExists(atPath: destFile.path)
        else {
            try? fileManager.removeItem(at: tempDir)
            throw PluginFetchError.downloadFailed(url: remoteURL, httpCode: httpCode)
        }

        return (destFile, tempDir)
    }

    /// Clones a git repository, removes the `.git` directory, packages the contents as a
    /// `.piqleyplugin` zip, and returns the zip path. The caller is responsible for
    /// removing the returned `tempDir`.
    static func cloneAndPackage(
        from repoURL: String,
        fileManager: any FileSystemManager = FileManager.default
    ) throws -> (fileURL: URL, tempDir: URL) {
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("piqley-git-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let cloneDir = tempDir.appendingPathComponent("repo")

        // Shallow clone for speed
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "clone", "--depth", "1", repoURL, cloneDir.path]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()

        guard git.terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempDir)
            throw PluginFetchError.cloneFailed(url: repoURL)
        }

        // Remove .git directory so it doesn't end up in the plugin installation
        let dotGit = cloneDir.appendingPathComponent(".git")
        try? fileManager.removeItem(at: dotGit)

        // Package as .piqleyplugin zip using the zip command (cross-platform)
        let zipFile = tempDir.appendingPathComponent("plugin.piqleyplugin")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        zip.arguments = ["zip", "-r", "-q", zipFile.path, cloneDir.lastPathComponent]
        zip.currentDirectoryURL = cloneDir.deletingLastPathComponent()
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()

        guard zip.terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempDir)
            throw PluginFetchError.packageFailed
        }

        return (zipFile, tempDir)
    }
}
