# Plugin Create Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `piqley plugin create` to scaffold standalone plugin projects from SDK skeleton templates.

**Architecture:** New `CreateSubcommand` on `PluginCommand` that resolves a compatible SDK version via `git ls-remote`, downloads the release tarball, extracts the language skeleton, copies it to the target directory, and performs template substitution. Version resolution and skeleton fetching are separated into testable units. The Swift skeleton boilerplate is committed to the `piqley-plugin-sdk` repo.

**Tech Stack:** Swift 6.2, ArgumentParser, Foundation (Process, URLSession, FileManager)

---

### Task 1: Write the Swift Skeleton in the SDK Repo

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/Skeletons/swift/Package.swift`
- Create: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/Skeletons/swift/Sources/main.swift`
- Create: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/Skeletons/swift/.gitignore`

- [ ] **Step 1: Create `Skeletons/swift/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "__PLUGIN_NAME__",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/josephquigley/piqley-plugin-sdk",
            .upToNextMajor(from: "__SDK_VERSION__")
        ),
    ],
    targets: [
        .executableTarget(
            name: "__PLUGIN_NAME__",
            dependencies: [
                .product(name: "PiqleyPluginSDK", package: "piqley-plugin-sdk"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create `Skeletons/swift/Sources/main.swift`**

```swift
import PiqleyPluginSDK

@main
struct Plugin: PiqleyPlugin {
    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        let images = try request.imageFiles()
        for image in images {
            request.reportProgress("Processing \(image.lastPathComponent)...")
            // TODO: Add your plugin logic here
            request.reportImageResult(image.lastPathComponent, success: true)
        }
        return .ok
    }

    static func main() async {
        await Plugin().run()
    }
}
```

- [ ] **Step 3: Create `Skeletons/swift/.gitignore`**

```
.DS_Store
/.build
/Packages
xcuserdata/
DerivedData/
.swiftpm/
Package.resolved
```

- [ ] **Step 4: Commit skeleton to SDK repo**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add Skeletons/swift/
git commit -m "feat: add Swift plugin skeleton for piqley plugin create"
```

---

### Task 2: Add SemVer Parsing Utility

**Files:**
- Create: `Sources/piqley/CLI/SemVer.swift`
- Create: `Tests/piqleyTests/SemVerTests.swift`

- [ ] **Step 1: Write failing tests for SemVer parsing**

In `Tests/piqleyTests/SemVerTests.swift`:

```swift
import Testing
@testable import piqley

@Suite("SemVer")
struct SemVerTests {
    @Test("parses basic version")
    func testBasicParse() throws {
        let v = try SemVer.parse("1.2.3")
        #expect(v.major == 1)
        #expect(v.minor == 2)
        #expect(v.patch == 3)
    }

    @Test("parses version with v prefix")
    func testVPrefix() throws {
        let v = try SemVer.parse("v0.1.0")
        #expect(v.major == 0)
        #expect(v.minor == 1)
        #expect(v.patch == 0)
    }

    @Test("rejects non-semver string")
    func testRejectsInvalid() {
        #expect(throws: (any Error).self) {
            try SemVer.parse("not-a-version")
        }
    }

    @Test("comparable sorts correctly")
    func testComparable() throws {
        let a = try SemVer.parse("0.1.0")
        let b = try SemVer.parse("0.2.0")
        let c = try SemVer.parse("0.1.5")
        #expect(a < c)
        #expect(c < b)
    }

    @Test("versionString strips v prefix")
    func testVersionString() throws {
        let v = try SemVer.parse("v1.2.3")
        #expect(v.versionString == "1.2.3")
    }

    @Test("isCompatible matches major for >= 1.0")
    func testCompatibleMajor() throws {
        let cli = try SemVer.parse("2.3.0")
        let tag = try SemVer.parse("2.1.0")
        let other = try SemVer.parse("1.9.0")
        #expect(cli.isCompatible(with: tag) == true)
        #expect(cli.isCompatible(with: other) == false)
    }

    @Test("isCompatible matches major+minor for 0.x")
    func testCompatibleMinor() throws {
        let cli = try SemVer.parse("0.1.0")
        let tag = try SemVer.parse("0.1.5")
        let other = try SemVer.parse("0.2.0")
        #expect(cli.isCompatible(with: tag) == true)
        #expect(cli.isCompatible(with: other) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SemVer 2>&1 | tail -5`
Expected: compilation failure — `SemVer` not defined

- [ ] **Step 3: Implement SemVer**

In `Sources/piqley/CLI/SemVer.swift`:

```swift
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
        if major >= 1 {
            return major == other.major
        }
        return major == other.major && minor == other.minor
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
        case .invalidFormat(let s): "Invalid semver: '\(s)'"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SemVer 2>&1 | tail -5`
Expected: all 7 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/CLI/SemVer.swift Tests/piqleyTests/SemVerTests.swift
git commit -m "feat: add SemVer parsing with compatibility matching"
```

---

### Task 3: Add SDK Version Resolver

**Files:**
- Create: `Sources/piqley/CLI/SDKVersionResolver.swift`
- Create: `Tests/piqleyTests/SDKVersionResolverTests.swift`

- [ ] **Step 1: Write failing tests for tag parsing and selection**

The resolver has two concerns: (a) running `git ls-remote` and (b) parsing the output + selecting the best tag. We test (b) with pure functions, and (a) integration-style.

In `Tests/piqleyTests/SDKVersionResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("SDKVersionResolver")
struct SDKVersionResolverTests {
    @Test("parses tags from git ls-remote output")
    func testParseTags() throws {
        let output = """
        abc123\trefs/tags/v0.1.0
        def456\trefs/tags/v0.1.1
        ghi789\trefs/tags/v0.2.0
        jkl012\trefs/tags/not-semver
        mno345\trefs/tags/v0.1.0^{}
        """
        let tags = SDKVersionResolver.parseTags(from: output)
        #expect(tags.count == 3)
        #expect(tags[0].versionString == "0.1.0")
        #expect(tags[1].versionString == "0.1.1")
        #expect(tags[2].versionString == "0.2.0")
    }

    @Test("selects highest compatible tag for 0.x")
    func testSelectsHighestCompatible() throws {
        let cli = try SemVer.parse("0.1.0")
        let tags = [
            try SemVer.parse("0.1.0"),
            try SemVer.parse("0.1.5"),
            try SemVer.parse("0.2.0"),
        ]
        let result = SDKVersionResolver.bestMatch(for: cli, from: tags)
        #expect(result?.versionString == "0.1.5")
    }

    @Test("returns nil when no compatible tag exists")
    func testNoMatch() throws {
        let cli = try SemVer.parse("0.3.0")
        let tags = [
            try SemVer.parse("0.1.0"),
            try SemVer.parse("0.2.0"),
        ]
        let result = SDKVersionResolver.bestMatch(for: cli, from: tags)
        #expect(result == nil)
    }

    @Test("selects highest compatible tag for >= 1.x")
    func testMajorVersionMatch() throws {
        let cli = try SemVer.parse("2.0.0")
        let tags = [
            try SemVer.parse("1.5.0"),
            try SemVer.parse("2.0.0"),
            try SemVer.parse("2.3.1"),
            try SemVer.parse("3.0.0"),
        ]
        let result = SDKVersionResolver.bestMatch(for: cli, from: tags)
        #expect(result?.versionString == "2.3.1")
    }

    @Test("ignores peeled tag refs")
    func testIgnoresPeeled() throws {
        let output = """
        abc123\trefs/tags/v0.1.0
        def456\trefs/tags/v0.1.0^{}
        """
        let tags = SDKVersionResolver.parseTags(from: output)
        #expect(tags.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SDKVersionResolver 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Implement SDKVersionResolver**

In `Sources/piqley/CLI/SDKVersionResolver.swift`:

```swift
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
    case skeletonNotFound(String, String)
    case targetNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case .gitLsRemoteFailed(let url, let code):
            "git ls-remote failed for '\(url)' (exit code \(code))"
        case .noCompatibleVersion(let version, let url):
            "No SDK release compatible with CLI version \(version) found at '\(url)'"
        case .tarballDownloadFailed(let url):
            "Failed to download tarball from '\(url)'"
        case .extractionFailed(let detail):
            "Failed to extract tarball: \(detail)"
        case .skeletonNotFound(let language, let version):
            "Skeleton for language '\(language)' not found in SDK release \(version)"
        case .targetNotEmpty(let path):
            "Target directory '\(path)' already exists and is not empty"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SDKVersionResolver 2>&1 | tail -5`
Expected: all 5 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/CLI/SDKVersionResolver.swift Tests/piqleyTests/SDKVersionResolverTests.swift
git commit -m "feat: add SDK version resolver with git ls-remote tag parsing"
```

---

### Task 4: Add Skeleton Fetcher

**Files:**
- Create: `Sources/piqley/CLI/SkeletonFetcher.swift`
- Create: `Tests/piqleyTests/SkeletonFetcherTests.swift`

- [ ] **Step 1: Write failing tests for skeleton extraction and template substitution**

We test the local operations (extraction, template substitution) using a fixture tarball. The network download is a thin wrapper tested via integration.

In `Tests/piqleyTests/SkeletonFetcherTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("SkeletonFetcher")
struct SkeletonFetcherTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-skeleton-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("replaces template placeholders in file contents")
    func testTemplateSubstitution() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("test.txt")
        try "name: __PLUGIN_NAME__, version: __SDK_VERSION__".write(to: file, atomically: true, encoding: .utf8)

        try SkeletonFetcher.applyTemplateSubstitutions(
            in: dir, pluginName: "my-plugin", sdkVersion: "0.1.0"
        )

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result == "name: my-plugin, version: 0.1.0")
    }

    @Test("substitution handles nested directories")
    func testNestedSubstitution() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let nested = dir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try "__PLUGIN_NAME__".write(to: file, atomically: true, encoding: .utf8)

        try SkeletonFetcher.applyTemplateSubstitutions(
            in: dir, pluginName: "test-plug", sdkVersion: "1.0.0"
        )

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result == "test-plug")
    }

    @Test("rejects non-empty target directory")
    func testRejectsNonEmptyTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a file so directory is non-empty
        try "content".write(
            to: dir.appendingPathComponent("existing.txt"),
            atomically: true, encoding: .utf8
        )

        #expect(throws: (any Error).self) {
            try SkeletonFetcher.validateTargetDirectory(dir)
        }
    }

    @Test("accepts empty target directory")
    func testAcceptsEmptyTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Should not throw
        try SkeletonFetcher.validateTargetDirectory(dir)
    }

    @Test("accepts non-existent target directory")
    func testAcceptsNonExistentTarget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-skeleton-test-\(UUID().uuidString)")
        // Do not create it
        try SkeletonFetcher.validateTargetDirectory(dir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SkeletonFetcher 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Implement SkeletonFetcher**

In `Sources/piqley/CLI/SkeletonFetcher.swift`:

```swift
import Foundation

enum SkeletonFetcher {
    /// Validate the target directory is empty or does not exist.
    static func validateTargetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            throw CreateError.targetNotEmpty(url.path)
        }
        let contents = try fm.contentsOfDirectory(atPath: url.path)
        if !contents.isEmpty {
            throw CreateError.targetNotEmpty(url.path)
        }
    }

    /// Download and extract the SDK tarball, returning the path to the skeleton directory.
    static func fetchAndExtractSkeleton(
        repoURL: String, tag: SemVer, language: String
    ) throws -> (skeletonDir: URL, tempDir: URL) {
        let tagString = "v\(tag.versionString)"
        let tarballURL = "\(repoURL)/archive/refs/tags/\(tagString).tar.gz"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tarballPath = tempDir.appendingPathComponent("sdk.tar.gz")

        // Download tarball
        let curlProcess = Process()
        curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        curlProcess.arguments = ["curl", "-sL", "-o", tarballPath.path, tarballURL]
        curlProcess.standardError = FileHandle.nullDevice
        try curlProcess.run()
        curlProcess.waitUntilExit()

        guard curlProcess.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tarballPath.path) else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.tarballDownloadFailed(tarballURL)
        }

        // Extract tarball
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        tarProcess.arguments = ["tar", "xzf", tarballPath.path, "-C", extractDir.path]
        try tarProcess.run()
        tarProcess.waitUntilExit()

        guard tarProcess.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.extractionFailed("tar exited with code \(tarProcess.terminationStatus)")
        }

        // Find the single top-level directory inside the extracted contents
        let extractedContents = try FileManager.default.contentsOfDirectory(
            at: extractDir, includingPropertiesForKeys: nil
        )
        guard let topLevel = extractedContents.first(where: {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }) else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.extractionFailed("No top-level directory found in archive")
        }

        let langLower = language.lowercased()
        let skeletonDir = topLevel.appendingPathComponent("Skeletons/\(langLower)")

        var isDirCheck: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skeletonDir.path, isDirectory: &isDirCheck),
              isDirCheck.boolValue else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.skeletonNotFound(langLower, tag.versionString)
        }

        return (skeletonDir, tempDir)
    }

    /// Copy skeleton contents to the target directory.
    static func copySkeleton(from skeletonDir: URL, to targetDir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: targetDir.path) {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let items = try fm.contentsOfDirectory(at: skeletonDir, includingPropertiesForKeys: nil)
        for item in items {
            let dest = targetDir.appendingPathComponent(item.lastPathComponent)
            try fm.copyItem(at: item, to: dest)
        }
    }

    /// Replace `__PLUGIN_NAME__` and `__SDK_VERSION__` in all files under a directory.
    static func applyTemplateSubstitutions(
        in directory: URL, pluginName: String, sdkVersion: String
    ) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let replaced = content
                .replacingOccurrences(of: "__PLUGIN_NAME__", with: pluginName)
                .replacingOccurrences(of: "__SDK_VERSION__", with: sdkVersion)

            if replaced != content {
                try replaced.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SkeletonFetcher 2>&1 | tail -5`
Expected: all 5 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/CLI/SkeletonFetcher.swift Tests/piqleyTests/SkeletonFetcherTests.swift
git commit -m "feat: add skeleton fetcher with download, extraction, and template substitution"
```

---

### Task 5: Add CreateSubcommand and Register It

**Files:**
- Create: `Sources/piqley/CLI/CreateCommand.swift`
- Modify: `Sources/piqley/CLI/PluginCommand.swift:11` (add `CreateSubcommand.self` to subcommands array)
- Create: `Tests/piqleyTests/PluginCreateTests.swift`

- [ ] **Step 1: Write failing tests for CreateSubcommand argument parsing and name derivation**

In `Tests/piqleyTests/PluginCreateTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("PluginCreate")
struct PluginCreateTests {
    @Test("derives plugin name from target directory")
    func testNameDerivation() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/my-cool-plugin"])
        #expect(cmd.resolvedPluginName == "my-cool-plugin")
    }

    @Test("explicit name overrides derivation")
    func testExplicitName() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/some-dir", "--name", "custom-name"])
        #expect(cmd.resolvedPluginName == "custom-name")
    }

    @Test("language defaults to swift")
    func testDefaultLanguage() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/test"])
        #expect(cmd.language == "swift")
    }

    @Test("language is lowercased")
    func testLanguageLowercased() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/test", "--language", "Swift"])
        #expect(cmd.resolvedLanguage == "swift")
    }

    @Test("sdk-repo-url has default value")
    func testDefaultSDKURL() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/test"])
        #expect(cmd.sdkRepoURL == "https://github.com/josephquigley/piqley-plugin-sdk")
    }

    @Test("sdk-repo-url can be overridden")
    func testCustomSDKURL() throws {
        let cmd = try PluginCommand.CreateSubcommand.parse([
            "/tmp/test", "--sdk-repo-url", "https://gitlab.example.com/org/sdk"
        ])
        #expect(cmd.sdkRepoURL == "https://gitlab.example.com/org/sdk")
    }

    @Test("validates derived plugin name")
    func testValidatesDerivedName() {
        // "original" is a reserved name
        #expect(throws: (any Error).self) {
            let cmd = try PluginCommand.CreateSubcommand.parse(["/tmp/original"])
            try cmd.validatePluginName()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginCreate 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Implement CreateSubcommand**

In `Sources/piqley/CLI/CreateCommand.swift`:

```swift
import ArgumentParser
import Foundation

extension PluginCommand {
    struct CreateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Scaffold a new plugin project from an SDK skeleton"
        )

        @Argument(help: "Target directory for the new plugin project")
        var targetDirectory: String

        @Option(name: .long, help: "Programming language for the skeleton (default: swift)")
        var language: String = "swift"

        @Option(name: .long, help: "Plugin name (derived from target directory if omitted)")
        var name: String?

        @Option(name: .long, help: "SDK repository URL")
        var sdkRepoURL: String = "https://github.com/josephquigley/piqley-plugin-sdk"

        var resolvedPluginName: String {
            name ?? URL(fileURLWithPath: targetDirectory).lastPathComponent
        }

        var resolvedLanguage: String {
            language.lowercased()
        }

        func validatePluginName() throws {
            try InitSubcommand.validatePluginName(resolvedPluginName)
        }

        func run() async throws {
            let pluginName = resolvedPluginName
            try InitSubcommand.validatePluginName(pluginName)

            let targetURL = URL(fileURLWithPath: targetDirectory)
            try SkeletonFetcher.validateTargetDirectory(targetURL)

            let cliVersion = try SemVer.parse(AppConstants.version)

            print("Resolving SDK version compatible with CLI v\(cliVersion.versionString)...")
            let sdkVersion = try SDKVersionResolver.resolve(
                cliVersion: cliVersion, repoURL: sdkRepoURL
            )
            print("Found SDK v\(sdkVersion.versionString)")

            print("Downloading skeleton...")
            let (skeletonDir, tempDir) = try SkeletonFetcher.fetchAndExtractSkeleton(
                repoURL: sdkRepoURL, tag: sdkVersion, language: resolvedLanguage
            )
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SkeletonFetcher.copySkeleton(from: skeletonDir, to: targetURL)
            try SkeletonFetcher.applyTemplateSubstitutions(
                in: targetURL, pluginName: pluginName, sdkVersion: sdkVersion.versionString
            )

            print("Created plugin '\(pluginName)' at \(targetURL.path)")
        }
    }
}
```

- [ ] **Step 4: Register CreateSubcommand in PluginCommand**

In `Sources/piqley/CLI/PluginCommand.swift`, change line 11 from:

```swift
        subcommands: [SetupSubcommand.self, InitSubcommand.self]
```

to:

```swift
        subcommands: [SetupSubcommand.self, InitSubcommand.self, CreateSubcommand.self]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PluginCreate 2>&1 | tail -5`
Expected: all 7 tests pass

- [ ] **Step 6: Run all tests to check for regressions**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/piqley/CLI/CreateCommand.swift Sources/piqley/CLI/PluginCommand.swift Tests/piqleyTests/PluginCreateTests.swift
git commit -m "feat: add piqley plugin create command"
```
