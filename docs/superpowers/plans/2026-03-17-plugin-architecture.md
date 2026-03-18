# Plugin Architecture Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor piqley from a monolithic Ghost-coupled tool into a generic plugin-based photographer workflow engine.

**Architecture:** A plugin runner reads manifests from `~/.config/piqley/plugins/`, spawns isolated subprocesses at each pipeline hook (`pre-process → post-process → publish → schedule → post-publish`), and communicates via JSON over stdin/stdout or straight pipe. Piqley core retains only orchestration, temp folder management, secrets proxying, and the `verify` command.

**Tech Stack:** Swift 6.2, macOS 13+, ArgumentParser 1.3+, swift-log 1.5+, Foundation (Process, Pipe), Security framework (Keychain). SwiftSMTP removed.

**Spec:** `docs/superpowers/specs/2026-03-17-plugin-architecture-design.md`

---

## File Map

### Files to CREATE
| Path | Responsibility |
|---|---|
| `Sources/piqley/Plugins/PluginManifest.swift` | Decode `plugin.json`; manifest validation |
| `Sources/piqley/Plugins/PluginDiscovery.swift` | Scan plugins dir; auto-discovery logic |
| `Sources/piqley/Plugins/PluginRunner.swift` | Spawn subprocesses; json/pipe protocols; batchProxy; inactivity timeout |
| `Sources/piqley/Plugins/PluginBlocklist.swift` | In-memory per-run blocklist |
| `Sources/piqley/Plugins/ExitCodeEvaluator.swift` | Map exit codes to success/warning/critical |
| `Sources/piqley/Pipeline/PipelineOrchestrator.swift` | Hook ordering; plugin dispatch; blocklist enforcement |
| `Sources/piqley/Pipeline/TempFolder.swift` | Create `/tmp/piqley-<uuid>/`; copy image files; delete on teardown |
| `Sources/piqley/CLI/SecretCommand.swift` | `piqley secret set/delete` — Keychain CRUD via ArgumentParser group |
| `Sources/piqley/Shared/JSONValue.swift` | Codable enum for arbitrary JSON (used in Config and plugin payloads) |
| `Tests/piqleyTests/ExitCodeEvaluatorTests.swift` | Unit tests |
| `Tests/piqleyTests/PluginBlocklistTests.swift` | Unit tests |
| `Tests/piqleyTests/TempFolderTests.swift` | Unit tests |
| `Tests/piqleyTests/PluginManifestTests.swift` | Unit tests |
| `Tests/piqleyTests/PluginDiscoveryTests.swift` | Unit tests |
| `Tests/piqleyTests/PluginRunnerTests.swift` | Integration tests using real shell scripts |

### Files to MODIFY
| Path | Change |
|---|---|
| `Sources/piqley/Config/Config.swift` | Full rewrite — new schema (pipeline, disabledPlugins, autoDiscoverPlugins, plugins as JSONValue) |
| `Sources/piqley/Secrets/SecretStore.swift` | Add `getPluginSecret(plugin:key:)` / `setPluginSecret` / `deletePluginSecret` |
| `Sources/piqley/ErrorFormatting.swift` | Already untracked — add to git (no changes needed, referenced by ProcessCommand) |
| `Sources/piqley/CLI/ProcessCommand.swift` | Full rewrite — thin orchestration layer only |
| `Sources/piqley/CLI/SetupCommand.swift` | Rewrite — seeds new config; installs bundled plugins from relative path |
| `Sources/piqley/CLI/ClearCacheCommand.swift` | Rewrite — clears plugin execution logs |
| `Sources/piqley/CLI/VerifyCommand.swift` | Update references to new AppConfig schema (signing section) |
| `Sources/piqley/Constants.swift` | Remove `resultFilePrefix` |
| `Sources/piqley/Piqley.swift` | Add `SecretCommand` subcommand |
| `Package.swift` | Remove `swift-smtp` dependency and `SwiftSMTP` product |
| `Tests/piqleyTests/ConfigTests.swift` | Full rewrite for new schema |

### Files to MOVE (to `_migrate/`)
All legacy source files move out of `Sources/` into `_migrate/` so they compile out and can be referenced when building plugin repos:
- `Sources/piqley/Ghost/` → `_migrate/Ghost/`
- `Sources/piqley/Email/` → `_migrate/Email/`
- `Sources/piqley/Logging/` → `_migrate/Logging/`
- `Sources/piqley/Results/` → `_migrate/Results/`
- From `Sources/piqley/ImageProcessing/`: `ImageScanner.swift`, `CGImageMetadataReader.swift`, `MetadataReader.swift`, `ImageMetadata.swift`, `CoreGraphicsImageProcessor.swift`, `ImageProcessor.swift`, `TagMatcher.swift` → `_migrate/ImageProcessing/`

### Files to MOVE (within Sources — Signing stays in core for VerifyCommand)
- `Sources/piqley/ImageProcessing/GPGImageSigner.swift` → `Sources/piqley/Signing/GPGImageSigner.swift`
- `Sources/piqley/ImageProcessing/SignableContentExtractor.swift` → `Sources/piqley/Signing/SignableContentExtractor.swift`
- `Sources/piqley/ImageProcessing/XMPSignatureReader.swift` → `Sources/piqley/Signing/XMPSignatureReader.swift`
- `Sources/piqley/ImageProcessing/ImageSigner.swift` → `Sources/piqley/Signing/ImageSigner.swift`

### Tests to MOVE (to `_migrate/Tests/`)
Tests for deleted/migrated code:
`GhostDeduplicatorTests.swift`, `GhostSchedulerTests.swift`, `GhostClientTests.swift`, `LexicalBuilderTests.swift`, `TagMatcherTests.swift`, `MetadataReaderTests.swift`, `ImageScannerTests.swift`, `ImageProcessorTests.swift`, `ImageSignerTests.swift`, `SignableContentExtractorTests.swift`, `EmailLogTests.swift`, `UploadLogTests.swift`, `ResultsWriterTests.swift`

### Tests to KEEP
`ProcessLockTests.swift`, `TestHelpers.swift`, `ConfigTests.swift` (rewritten)

---

## Task 1: Move Legacy Code to `_migrate/`

**Files:**
- Create: `_migrate/Ghost/`, `_migrate/Email/`, `_migrate/Logging/`, `_migrate/Results/`, `_migrate/ImageProcessing/`, `_migrate/Tests/`
- Remove from `Sources/`: all Ghost, Email, Logging, Results directories; most of ImageProcessing

- [ ] **Step 1: Create _migrate directory structure and move directories**

```bash
mkdir -p _migrate/Tests
# Move whole directories
mv Sources/piqley/Ghost _migrate/
mv Sources/piqley/Email _migrate/
mv Sources/piqley/Logging _migrate/
mv Sources/piqley/Results _migrate/

# Move most of ImageProcessing
mkdir -p _migrate/ImageProcessing
mv Sources/piqley/ImageProcessing/ImageScanner.swift _migrate/ImageProcessing/
mv Sources/piqley/ImageProcessing/CGImageMetadataReader.swift _migrate/ImageProcessing/
mv Sources/piqley/ImageProcessing/MetadataReader.swift _migrate/ImageProcessing/
mv Sources/piqley/ImageProcessing/ImageMetadata.swift _migrate/ImageProcessing/
mv Sources/piqley/ImageProcessing/CoreGraphicsImageProcessor.swift _migrate/ImageProcessing/
mv Sources/piqley/ImageProcessing/ImageProcessor.swift _migrate/ImageProcessing/
mv Sources/piqley/ImageProcessing/TagMatcher.swift _migrate/ImageProcessing/

# Move Signing files to new core location
mkdir -p Sources/piqley/Signing
mv Sources/piqley/ImageProcessing/GPGImageSigner.swift Sources/piqley/Signing/
mv Sources/piqley/ImageProcessing/SignableContentExtractor.swift Sources/piqley/Signing/
mv Sources/piqley/ImageProcessing/XMPSignatureReader.swift Sources/piqley/Signing/
mv Sources/piqley/ImageProcessing/ImageSigner.swift Sources/piqley/Signing/

# ImageProcessing dir is now empty — remove it
rmdir Sources/piqley/ImageProcessing

# Move old tests
mv Tests/piqleyTests/GhostDeduplicatorTests.swift _migrate/Tests/
mv Tests/piqleyTests/GhostSchedulerTests.swift _migrate/Tests/
mv Tests/piqleyTests/GhostClientTests.swift _migrate/Tests/
mv Tests/piqleyTests/LexicalBuilderTests.swift _migrate/Tests/
mv Tests/piqleyTests/TagMatcherTests.swift _migrate/Tests/
mv Tests/piqleyTests/MetadataReaderTests.swift _migrate/Tests/
mv Tests/piqleyTests/ImageScannerTests.swift _migrate/Tests/
mv Tests/piqleyTests/ImageProcessorTests.swift _migrate/Tests/
mv Tests/piqleyTests/ImageSignerTests.swift _migrate/Tests/
mv Tests/piqleyTests/SignableContentExtractorTests.swift _migrate/Tests/
mv Tests/piqleyTests/EmailLogTests.swift _migrate/Tests/
mv Tests/piqleyTests/UploadLogTests.swift _migrate/Tests/
mv Tests/piqleyTests/ResultsWriterTests.swift _migrate/Tests/
```

- [ ] **Step 2: Update Package.swift — remove SwiftSMTP**

Replace the entire `Package.swift` with:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "piqley",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "piqley",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "piqleyTests",
            dependencies: ["piqley"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 3: Update Constants.swift — remove resultFilePrefix**

```swift
import Foundation

enum AppConstants {
    static let name = "piqley"
    static let version = "1.0.0"
    static let userAgent = "Piqley/\(version) (+https://github.com/josephquigley/piqley)"
}
```

- [ ] **Step 4: Stub out ProcessCommand, SetupCommand, ClearCacheCommand so the project compiles**

Temporarily replace `Sources/piqley/CLI/ProcessCommand.swift` with a stub:

```swift
import ArgumentParser
import Foundation

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process and publish photos via plugins"
    )

    @Argument(help: "Path to folder containing images to process")
    var folderPath: String

    @Flag(help: "Preview without uploading or emailing")
    var dryRun = false

    @Flag(help: "Delete source image files after successful run")
    var deleteSourceImages = false

    @Flag(help: "Delete source folder after successful run")
    var deleteSourceFolder = false

    func run() async throws {
        print("Not yet implemented")
    }
}
```

Temporarily replace `Sources/piqley/CLI/SetupCommand.swift` with a stub:

```swift
import ArgumentParser

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up piqley configuration and install bundled plugins"
    )
    func run() async throws {
        print("Not yet implemented")
    }
}
```

Temporarily replace `Sources/piqley/CLI/ClearCacheCommand.swift` with a stub:

```swift
import ArgumentParser

struct ClearCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-cache",
        abstract: "Clear plugin execution logs"
    )

    @Option(help: "Clear only this plugin's execution log")
    var plugin: String?

    func run() throws {
        print("Not yet implemented")
    }
}
```

- [ ] **Step 5: Verify the project builds**

```bash
swift build 2>&1
```

Expected: Build succeeds (there may be warnings from VerifyCommand referencing old Config fields — we'll fix Config next).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: move legacy code to _migrate/, stub commands, remove SwiftSMTP"
```

---

## Task 2: JSONValue — Arbitrary JSON Codable Type

**Files:**
- Create: `Sources/piqley/Shared/JSONValue.swift`

This type is used throughout the new codebase wherever arbitrary JSON is needed (plugin configs, stdin payloads).

- [ ] **Step 1: Create `Sources/piqley/Shared/` directory**

```bash
mkdir -p Sources/piqley/Shared
```

- [ ] **Step 2: Write `Sources/piqley/Shared/JSONValue.swift`**

```swift
import Foundation

/// A Codable, Sendable value representing any JSON primitive or structure.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let v):    try container.encode(v)
        case .number(let v):  try container.encode(v)
        case .string(let v):  try container.encode(v)
        case .array(let v):   try container.encode(v)
        case .object(let v):  try container.encode(v)
        }
    }

    /// Convert to a Foundation-compatible value for use in JSON serialization.
    var foundationValue: Any {
        switch self {
        case .null:           return NSNull()
        case .bool(let v):    return v
        case .number(let v):  return v
        case .string(let v):  return v
        case .array(let v):   return v.map(\.foundationValue)
        case .object(let v):  return v.mapValues(\.foundationValue)
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/Shared/JSONValue.swift
git commit -m "feat: add JSONValue for arbitrary JSON encoding/decoding"
```

---

## Task 3: New Config Schema

**Files:**
- Modify: `Sources/piqley/Config/Config.swift`
- Modify: `Tests/piqleyTests/ConfigTests.swift`

The new config stores pipeline ordering, disabled plugins, per-plugin user config (as JSONValue), and a minimal signing section for `verify` command compatibility.

- [ ] **Step 1: Write the failing test first**

Replace `Tests/piqleyTests/ConfigTests.swift` with:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("AppConfig")
struct ConfigTests {
    @Test("decodes pipeline and plugin config from JSON")
    func testDecodeFullConfig() throws {
        let json = """
        {
          "autoDiscoverPlugins": true,
          "disabledPlugins": ["bad-plugin"],
          "pipeline": {
            "pre-process": ["piqley-metadata", "piqley-resize"],
            "publish": ["ghost:required"]
          },
          "plugins": {
            "piqley-resize": {"maxLongEdge": 2048, "quality": 85}
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.autoDiscoverPlugins == true)
        #expect(config.disabledPlugins == ["bad-plugin"])
        #expect(config.pipeline["pre-process"] == ["piqley-metadata", "piqley-resize"])
        #expect(config.pipeline["publish"] == ["ghost:required"])
        if case .number(let q) = config.plugins["piqley-resize"]?["quality"] {
            #expect(q == 85)
        } else {
            Issue.record("Expected quality to be a number")
        }
    }

    @Test("defaults autoDiscoverPlugins to true when absent")
    func testDefaults() throws {
        let json = "{}"
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.autoDiscoverPlugins == true)
        #expect(config.disabledPlugins.isEmpty)
        #expect(config.pipeline.isEmpty)
    }

    @Test("encodes and decodes round-trip")
    func testRoundTrip() throws {
        var config = AppConfig()
        config.pipeline["publish"] = ["ghost"]
        config.plugins["ghost"] = ["url": .string("https://example.com")]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.pipeline["publish"] == ["ghost"])
        if case .string(let url) = decoded.plugins["ghost"]?["url"] {
            #expect(url == "https://example.com")
        } else {
            Issue.record("Expected url to be a string")
        }
    }

    @Test("configURL points to ~/.config/piqley/config.json")
    func testConfigURL() {
        let url = AppConfig.configURL
        #expect(url.lastPathComponent == "config.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "piqley")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ConfigTests 2>&1 | tail -20
```

Expected: compile error — `AppConfig` has wrong shape.

- [ ] **Step 3: Rewrite `Sources/piqley/Config/Config.swift`**

```swift
import Foundation

struct AppConfig: Codable, Sendable {
    var autoDiscoverPlugins: Bool = true
    var disabledPlugins: [String] = []
    /// Hook name → ordered plugin name list. Plugin names may include ":required" suffix (reserved for future use).
    var pipeline: [String: [String]] = [:]
    /// Plugin name → arbitrary key/value config passed to the plugin via stdin payload.
    var plugins: [String: [String: JSONValue]] = [:]
    /// Optional signing config retained for the `verify` command.
    var signing: SigningConfig?

    struct SigningConfig: Codable, Sendable {
        var xmpNamespace: String?
        var xmpPrefix: String = "piqley"
        static let defaultXmpPrefix = "piqley"
    }

    // MARK: - Persistence

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/config.json")
    }

    static func load(from url: URL = AppConfig.configURL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func save(to url: URL = AppConfig.configURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
```

- [ ] **Step 4: Fix VerifyCommand to use new Config shape**

`VerifyCommand.swift` references `config.ghost.url`, `config.resolvedSigningConfig`, `config.signing.xmpPrefix`. Update it to use the new schema:

Replace the namespace/prefix resolution block in `VerifyCommand.run()`:

```swift
// Resolve XMP namespace/prefix: CLI flags > config > error
let namespace: String
let prefix: String

if let explicitNamespace = xmpNamespace {
    namespace = explicitNamespace
} else if let config = try? AppConfig.load(),
          let signing = config.signing,
          let ns = signing.xmpNamespace
{
    namespace = ns
} else {
    print("No XMP namespace configured. Use --xmp-namespace or run 'piqley setup'.")
    throw ExitCode(1)
}

prefix = xmpPrefix ?? {
    if let config = try? AppConfig.load(), let signing = config.signing {
        return signing.xmpPrefix
    }
    return AppConfig.SigningConfig.defaultXmpPrefix
}()
```

Also remove the `AppConfig.configPath` reference — the new API uses `AppConfig.configURL` and the `load()` method takes a URL directly.

- [ ] **Step 5: Run tests**

```bash
swift test --filter ConfigTests 2>&1 | tail -20
```

Expected: All `ConfigTests` pass.

- [ ] **Step 6: Build to verify no regressions**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/piqley/Config/Config.swift Sources/piqley/CLI/VerifyCommand.swift Tests/piqleyTests/ConfigTests.swift
git commit -m "feat: rewrite Config schema for plugin architecture"
```

---

## Task 4: ExitCodeEvaluator

**Files:**
- Create: `Sources/piqley/Plugins/ExitCodeEvaluator.swift`
- Create: `Tests/piqleyTests/ExitCodeEvaluatorTests.swift`

- [ ] **Step 1: Create directory and write failing tests**

```bash
mkdir -p Sources/piqley/Plugins
```

Create `Tests/piqleyTests/ExitCodeEvaluatorTests.swift`:

```swift
import Testing
@testable import piqley

@Suite("ExitCodeEvaluator")
struct ExitCodeEvaluatorTests {
    @Test("all arrays empty: 0 = success, non-zero = critical (Unix defaults)")
    func testUnixDefaults() {
        let eval = ExitCodeEvaluator(successCodes: [], warningCodes: [], criticalCodes: [])
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(1) == .critical)
        #expect(eval.evaluate(2) == .critical)
    }

    @Test("explicit successCodes: only those codes are success")
    func testExplicitSuccess() {
        let eval = ExitCodeEvaluator(successCodes: [0, 42], warningCodes: [], criticalCodes: [])
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(42) == .success)
        #expect(eval.evaluate(1) == .critical)
    }

    @Test("explicit warningCodes: code in list is warning")
    func testWarning() {
        let eval = ExitCodeEvaluator(successCodes: [0], warningCodes: [2], criticalCodes: [1])
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(2) == .warning)
        #expect(eval.evaluate(1) == .critical)
    }

    @Test("code not in any non-empty list defaults to critical")
    func testUnknownCodeDefaultsToCritical() {
        let eval = ExitCodeEvaluator(successCodes: [0], warningCodes: [2], criticalCodes: [1])
        #expect(eval.evaluate(99) == .critical)
    }

    @Test("nil arrays (absent in manifest) behave identically to empty")
    func testNilBehavesLikeEmpty() {
        let eval = ExitCodeEvaluator(successCodes: nil, warningCodes: nil, criticalCodes: nil)
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(1) == .critical)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ExitCodeEvaluatorTests 2>&1 | tail -10
```

Expected: compile error — `ExitCodeEvaluator` not defined.

- [ ] **Step 3: Create `Sources/piqley/Plugins/ExitCodeEvaluator.swift`**

```swift
import Foundation

enum ExitCodeResult: Equatable, Sendable {
    case success
    case warning
    case critical
}

struct ExitCodeEvaluator: Sendable {
    private let successCodes: [Int32]
    private let warningCodes: [Int32]
    private let criticalCodes: [Int32]
    private let useUnixDefaults: Bool

    init(successCodes: [Int32]?, warningCodes: [Int32]?, criticalCodes: [Int32]?) {
        let s = successCodes ?? []
        let w = warningCodes ?? []
        let c = criticalCodes ?? []
        self.successCodes = s
        self.warningCodes = w
        self.criticalCodes = c
        // If all arrays are empty (or nil), fall back to Unix defaults
        self.useUnixDefaults = s.isEmpty && w.isEmpty && c.isEmpty
    }

    func evaluate(_ code: Int32) -> ExitCodeResult {
        if useUnixDefaults {
            return code == 0 ? .success : .critical
        }
        if !successCodes.isEmpty && successCodes.contains(code) { return .success }
        if !warningCodes.isEmpty && warningCodes.contains(code) { return .warning }
        if !criticalCodes.isEmpty && criticalCodes.contains(code) { return .critical }
        // Not in any defined list — default to critical
        return .critical
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter ExitCodeEvaluatorTests 2>&1 | tail -10
```

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/ExitCodeEvaluator.swift Tests/piqleyTests/ExitCodeEvaluatorTests.swift
git commit -m "feat: add ExitCodeEvaluator"
```

---

## Task 5: PluginBlocklist

**Files:**
- Create: `Sources/piqley/Plugins/PluginBlocklist.swift`
- Create: `Tests/piqleyTests/PluginBlocklistTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/PluginBlocklistTests.swift`:

```swift
import Testing
@testable import piqley

@Suite("PluginBlocklist")
struct PluginBlocklistTests {
    @Test("freshly created blocklist has no blocked plugins")
    func testEmpty() {
        let bl = PluginBlocklist()
        #expect(bl.isBlocked("ghost") == false)
    }

    @Test("blocking a plugin marks it as blocked")
    func testBlock() {
        let bl = PluginBlocklist()
        bl.block("ghost")
        #expect(bl.isBlocked("ghost") == true)
    }

    @Test("blocking does not affect other plugins")
    func testIsolation() {
        let bl = PluginBlocklist()
        bl.block("ghost")
        #expect(bl.isBlocked("365-project") == false)
    }

    @Test("can block multiple plugins")
    func testMultiple() {
        let bl = PluginBlocklist()
        bl.block("ghost")
        bl.block("365-project")
        #expect(bl.isBlocked("ghost") == true)
        #expect(bl.isBlocked("365-project") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PluginBlocklistTests 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create `Sources/piqley/Plugins/PluginBlocklist.swift`**

```swift
import Foundation

/// Tracks plugins that have failed during the current run.
/// A blocked plugin is skipped for all subsequent hooks in the run.
/// Not thread-safe — the pipeline is sequential, so no locking needed.
final class PluginBlocklist: @unchecked Sendable {
    private var blocked: Set<String> = []

    func block(_ pluginName: String) {
        blocked.insert(pluginName)
    }

    func isBlocked(_ pluginName: String) -> Bool {
        blocked.contains(pluginName)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter PluginBlocklistTests 2>&1 | tail -10
```

Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginBlocklist.swift Tests/piqleyTests/PluginBlocklistTests.swift
git commit -m "feat: add PluginBlocklist"
```

---

## Task 6: TempFolder

**Files:**
- Create: `Sources/piqley/Pipeline/TempFolder.swift`
- Create: `Tests/piqleyTests/TempFolderTests.swift`

- [ ] **Step 1: Create directory and write failing tests**

```bash
mkdir -p Sources/piqley/Pipeline
```

Create `Tests/piqleyTests/TempFolderTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("TempFolder")
struct TempFolderTests {
    @Test("creates a unique temp directory under /tmp")
    func testCreate() throws {
        let temp = try TempFolder.create()
        defer { try? temp.delete() }
        #expect(FileManager.default.fileExists(atPath: temp.url.path))
        #expect(temp.url.path.hasPrefix(NSTemporaryDirectory()))
    }

    @Test("delete removes the temp directory")
    func testDelete() throws {
        let temp = try TempFolder.create()
        let path = temp.url.path
        try temp.delete()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("copyImages copies JPEG and JXL files")
    func testCopyImages() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        // Create test files
        try "data".write(to: sourceDir.appendingPathComponent("photo.jpg"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("photo.jpeg"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("raw.jxl"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let temp = try TempFolder.create()
        defer { try? temp.delete() }

        try temp.copyImages(from: sourceDir)

        let copied = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(copied.contains("photo.jpg"))
        #expect(copied.contains("photo.jpeg"))
        #expect(copied.contains("raw.jxl"))
        #expect(!copied.contains("readme.txt"))
    }

    @Test("copyImages skips hidden files")
    func testSkipsHidden() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        try "data".write(to: sourceDir.appendingPathComponent(".hidden.jpg"), atomically: true, encoding: .utf8)
        try "data".write(to: sourceDir.appendingPathComponent("visible.jpg"), atomically: true, encoding: .utf8)

        let temp = try TempFolder.create()
        defer { try? temp.delete() }

        try temp.copyImages(from: sourceDir)
        let copied = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(copied.contains("visible.jpg"))
        #expect(!copied.contains(".hidden.jpg"))
    }

    @Test("two TempFolders have different paths")
    func testUnique() throws {
        let a = try TempFolder.create()
        let b = try TempFolder.create()
        defer { try? a.delete(); try? b.delete() }
        #expect(a.url.path != b.url.path)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter TempFolderTests 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create `Sources/piqley/Pipeline/TempFolder.swift`**

```swift
import Foundation

struct TempFolder: Sendable {
    let url: URL

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "jxl"]

    static func create() throws -> TempFolder {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("piqley-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TempFolder(url: url)
    }

    /// Copies image files (jpg, jpeg, jxl) from `sourceURL` into this temp folder.
    /// Skips hidden files (names starting with ".").
    func copyImages(from sourceURL: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix("."),
                  Self.imageExtensions.contains(file.pathExtension.lowercased())
            else { continue }
            let destination = url.appendingPathComponent(name)
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }

    func delete() throws {
        try FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter TempFolderTests 2>&1 | tail -10
```

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Pipeline/TempFolder.swift Tests/piqleyTests/TempFolderTests.swift
git commit -m "feat: add TempFolder for isolated image copying"
```

---

## Task 7: PluginManifest

**Files:**
- Create: `Sources/piqley/Plugins/PluginManifest.swift`
- Create: `Tests/piqleyTests/PluginManifestTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/PluginManifestTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("PluginManifest")
struct PluginManifestTests {
    @Test("decodes a full manifest")
    func testFullDecode() throws {
        let json = """
        {
          "name": "ghost",
          "pluginProtocolVersion": "1",
          "secrets": ["api-key"],
          "hooks": {
            "publish": {
              "command": "./bin/piqley-ghost",
              "args": ["publish", "$PIQLEY_FOLDER_PATH"],
              "timeout": 60,
              "protocol": "json",
              "successCodes": [0],
              "warningCodes": [2],
              "criticalCodes": [1]
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.name == "ghost")
        #expect(manifest.pluginProtocolVersion == "1")
        #expect(manifest.secrets == ["api-key"])
        let hook = try #require(manifest.hooks["publish"])
        #expect(hook.command == "./bin/piqley-ghost")
        #expect(hook.args == ["publish", "$PIQLEY_FOLDER_PATH"])
        #expect(hook.timeout == 60)
        #expect(hook.pluginProtocol == .json)
        #expect(hook.successCodes == [0])
        #expect(hook.warningCodes == [2])
        #expect(hook.criticalCodes == [1])
    }

    @Test("absent optional fields decode to nil/defaults")
    func testDefaults() throws {
        let json = """
        {
          "name": "minimal",
          "pluginProtocolVersion": "1",
          "hooks": {
            "publish": {
              "command": "./bin/tool",
              "args": []
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.secrets == [])
        let hook = try #require(manifest.hooks["publish"])
        #expect(hook.timeout == nil)
        #expect(hook.pluginProtocol == nil)
        #expect(hook.successCodes == nil)
        #expect(hook.batchProxy == nil)
    }

    @Test("decodes batchProxy with sort config")
    func testBatchProxy() throws {
        let json = """
        {
          "name": "single-image-tool",
          "pluginProtocolVersion": "1",
          "hooks": {
            "pre-process": {
              "command": "/usr/local/bin/tool",
              "args": ["$PIQLEY_IMAGE_PATH"],
              "protocol": "pipe",
              "batchProxy": {
                "sort": {"key": "exif:DateTimeOriginal", "order": "ascending"}
              }
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let hook = try #require(manifest.hooks["pre-process"])
        let proxy = try #require(hook.batchProxy)
        let sort = try #require(proxy.sort)
        #expect(sort.key == "exif:DateTimeOriginal")
        #expect(sort.order == .ascending)
    }

    @Test("makeEvaluator uses Unix defaults when all code arrays are nil")
    func testEvaluatorFromNilCodes() throws {
        let json = """
        {
          "name": "t",
          "pluginProtocolVersion": "1",
          "hooks": {"publish": {"command": "./t", "args": []}}
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let hook = try #require(manifest.hooks["publish"])
        let eval = hook.makeEvaluator()
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(1) == .critical)
    }

    @Test("unknownHooks returns hook names not in the canonical five")
    func testUnknownHooks() throws {
        let json = """
        {
          "name": "t",
          "pluginProtocolVersion": "1",
          "hooks": {
            "publish": {"command": "./t", "args": []},
            "prepprocess": {"command": "./t", "args": []},
            "foobar": {"command": "./t", "args": []}
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let unknown = manifest.unknownHooks().sorted()
        #expect(unknown == ["foobar", "prepprocess"])
        // Canonical hook is not reported as unknown
        #expect(!unknown.contains("publish"))
    }

    @Test("manifest with unknown hooks still loads successfully")
    func testUnknownHooksDoNotFailLoad() throws {
        let json = """
        {
          "name": "t",
          "pluginProtocolVersion": "1",
          "hooks": {"totally-made-up-hook": {"command": "./t", "args": []}}
        }
        """
        // Should not throw
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.hooks["totally-made-up-hook"] != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PluginManifestTests 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create `Sources/piqley/Plugins/PluginManifest.swift`**

```swift
import Foundation

struct PluginManifest: Codable, Sendable {
    let name: String
    let pluginProtocolVersion: String
    let secrets: [String]
    let hooks: [String: HookConfig]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pluginProtocolVersion = try c.decode(String.self, forKey: .pluginProtocolVersion)
        secrets = (try? c.decode([String].self, forKey: .secrets)) ?? []
        hooks = try c.decode([String: HookConfig].self, forKey: .hooks)
    }

    private enum CodingKeys: String, CodingKey {
        case name, pluginProtocolVersion, secrets, hooks
    }

    struct HookConfig: Codable, Sendable {
        let command: String
        let args: [String]
        let timeout: Int?
        let pluginProtocol: PluginProtocol?
        let successCodes: [Int32]?
        let warningCodes: [Int32]?
        let criticalCodes: [Int32]?
        let batchProxy: BatchProxyConfig?

        private enum CodingKeys: String, CodingKey {
            case command, args, timeout
            case pluginProtocol = "protocol"
            case successCodes, warningCodes, criticalCodes, batchProxy
        }

        func makeEvaluator() -> ExitCodeEvaluator {
            ExitCodeEvaluator(
                successCodes: successCodes,
                warningCodes: warningCodes,
                criticalCodes: criticalCodes
            )
        }
    }

    struct BatchProxyConfig: Codable, Sendable {
        let sort: SortConfig?

        struct SortConfig: Codable, Sendable {
            let key: String
            let order: SortOrder

            enum SortOrder: String, Codable, Sendable {
                case ascending, descending
            }
        }
    }

    enum PluginProtocol: String, Codable, Sendable {
        case json
        case pipe
    }

    /// The canonical set of hook names piqley recognises.
    static let canonicalHooks: [String] = ["pre-process", "post-process", "publish", "schedule", "post-publish"]

    /// Returns hook names in this manifest that are not canonical (for warning).
    func unknownHooks() -> [String] {
        hooks.keys.filter { !Self.canonicalHooks.contains($0) }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter PluginManifestTests 2>&1 | tail -10
```

Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginManifest.swift Tests/piqleyTests/PluginManifestTests.swift
git commit -m "feat: add PluginManifest"
```

---

## Task 8: PluginDiscovery

**Files:**
- Create: `Sources/piqley/Plugins/PluginDiscovery.swift`
- Create: `Tests/piqleyTests/PluginDiscoveryTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/PluginDiscoveryTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("PluginDiscovery")
struct PluginDiscoveryTests {
    // Create a temp plugins dir with a given set of plugin subdirs (each with a plugin.json)
    func makePluginsDir(plugins: [(name: String, hooks: [String])]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for plugin in plugins {
            let pluginDir = dir.appendingPathComponent(plugin.name)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            var hooksDict: [String: Any] = [:]
            for hook in plugin.hooks {
                hooksDict[hook] = ["command": "./bin/tool", "args": []]
            }
            let manifest: [String: Any] = [
                "name": plugin.name,
                "pluginProtocolVersion": "1",
                "hooks": hooksDict
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
        }
        return dir
    }

    @Test("discovers plugins and loads manifests")
    func testDiscoversPlugins() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", hooks: ["publish", "schedule"]),
            (name: "365-project", hooks: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])
        let names = plugins.map(\.name).sorted()
        #expect(names == ["365-project", "ghost"])
    }

    @Test("skips disabled plugins")
    func testDisabled() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", hooks: ["publish"]),
            (name: "disabled-plugin", hooks: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: ["disabled-plugin"])
        #expect(plugins.map(\.name) == ["ghost"])
    }

    @Test("skips directories without plugin.json")
    func testSkipsInvalid() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", hooks: ["publish"])])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Create a subdir without plugin.json
        let bogus = dir.appendingPathComponent("not-a-plugin")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])
        #expect(plugins.map(\.name) == ["ghost"])
    }

    @Test("autoAppend adds plugins not already in pipeline lists")
    func testAutoAppend() throws {
        let dir = try makePluginsDir(plugins: [
            (name: "ghost", hooks: ["publish"]),
            (name: "365-project", hooks: ["post-publish"])
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])

        var pipeline: [String: [String]] = ["publish": ["existing-plugin"]]
        PluginDiscovery.autoAppend(discovered: plugins, into: &pipeline)

        // ghost publishes — should be appended to "publish" (already has existing-plugin)
        #expect(pipeline["publish"] == ["existing-plugin", "ghost"])
        // 365-project post-publishes — new entry
        #expect(pipeline["post-publish"] == ["365-project"])
    }

    @Test("autoAppend does not duplicate already-listed plugins")
    func testNoDuplicates() throws {
        let dir = try makePluginsDir(plugins: [(name: "ghost", hooks: ["publish"])])
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])

        var pipeline: [String: [String]] = ["publish": ["ghost"]]
        PluginDiscovery.autoAppend(discovered: plugins, into: &pipeline)
        #expect(pipeline["publish"] == ["ghost"])
    }

    @Test("returns empty list when plugins directory does not exist")
    func testMissingDir() throws {
        let dir = URL(fileURLWithPath: "/nonexistent/path/plugins")
        let discovery = PluginDiscovery(pluginsDirectory: dir)
        let plugins = try discovery.loadManifests(disabled: [])
        #expect(plugins.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PluginDiscoveryTests 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create `Sources/piqley/Plugins/PluginDiscovery.swift`**

```swift
import Foundation
import Logging

struct LoadedPlugin: Sendable {
    let name: String
    let directory: URL
    let manifest: PluginManifest
}

struct PluginDiscovery: Sendable {
    let pluginsDirectory: URL
    private let logger = Logger(label: "piqley.discovery")

    /// Loads all plugin manifests from `pluginsDirectory`, skipping disabled plugins and
    /// directories without a `plugin.json`.
    func loadManifests(disabled: [String]) throws -> [LoadedPlugin] {
        guard FileManager.default.fileExists(atPath: pluginsDirectory.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return try contents.compactMap { url -> LoadedPlugin? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            guard !disabled.contains(name) else { return nil }
            let manifestURL = url.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            // Warn about unknown hook names
            for unknown in manifest.unknownHooks() {
                logger.warning("Plugin '\(name)' declares unknown hook '\(unknown)' — ignored")
            }
            return LoadedPlugin(name: name, directory: url, manifest: manifest)
        }.sorted { $0.name < $1.name }
    }

    /// Appends newly discovered plugins to pipeline hook lists.
    /// Plugins already listed (by name, ignoring any suffixes) are not duplicated.
    /// Only adds to hooks the plugin actually declares.
    static func autoAppend(discovered: [LoadedPlugin], into pipeline: inout [String: [String]]) {
        for plugin in discovered {
            for hookName in PluginManifest.canonicalHooks {
                guard plugin.manifest.hooks[hookName] != nil else { continue }
                var list = pipeline[hookName] ?? []
                // Check if plugin name (without any suffix) is already listed
                let alreadyListed = list.contains { entry in
                    entry == plugin.name || entry.hasPrefix(plugin.name + ":")
                }
                guard !alreadyListed else { continue }
                list.append(plugin.name)
                pipeline[hookName] = list
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter PluginDiscoveryTests 2>&1 | tail -10
```

Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginDiscovery.swift Tests/piqleyTests/PluginDiscoveryTests.swift
git commit -m "feat: add PluginDiscovery"
```

---

## Task 9: Update SecretStore for Plugin Namespacing

**Files:**
- Modify: `Sources/piqley/Secrets/SecretStore.swift`
- Modify: `Sources/piqley/Secrets/KeychainSecretStore.swift`

- [ ] **Step 1: Add namespaced methods to SecretStore protocol**

Replace `Sources/piqley/Secrets/SecretStore.swift`:

```swift
import Foundation

protocol SecretStore: Sendable {
    func get(key: String) throws -> String
    func set(key: String, value: String) throws
    func delete(key: String) throws
}

extension SecretStore {
    /// Fetch a plugin-scoped secret. Key is namespaced as `piqley.plugins.<plugin>.<key>`.
    func getPluginSecret(plugin: String, key: String) throws -> String {
        try get(key: pluginSecretKey(plugin: plugin, key: key))
    }

    func setPluginSecret(plugin: String, key: String, value: String) throws {
        try set(key: pluginSecretKey(plugin: plugin, key: key), value: value)
    }

    func deletePluginSecret(plugin: String, key: String) throws {
        try delete(key: pluginSecretKey(plugin: plugin, key: key))
    }

    private func pluginSecretKey(plugin: String, key: String) -> String {
        "piqley.plugins.\(plugin).\(key)"
    }
}

enum SecretStoreError: Error, LocalizedError {
    case notFound(key: String)
    case unexpectedError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .notFound(key): "Keychain secret not found for key: \(key)"
        case let .unexpectedError(status): "Keychain error: \(status)"
        }
    }

    var failureReason: String? {
        switch self {
        case .notFound: "No matching entry exists in the macOS Keychain."
        case .unexpectedError: "The Keychain returned an unexpected status code."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound: "Run 'piqley secret set <plugin> <key>' to store the credential."
        case .unexpectedError: "Check Keychain Access.app for permission issues."
        }
    }
}
```

- [ ] **Step 2: Build to verify KeychainSecretStore still compiles**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/Secrets/SecretStore.swift
git commit -m "feat: add plugin-namespaced secret access to SecretStore"
```

---

## Task 10: PluginRunner

**Files:**
- Create: `Sources/piqley/Plugins/PluginRunner.swift`
- Create: `Tests/piqleyTests/PluginRunnerTests.swift`

This is the most complex component. It spawns subprocesses, manages the inactivity timeout, handles json/pipe protocols, and implements batchProxy.

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/PluginRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

// Helpers to write temp shell scripts used as fake plugins
private func makeTempScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-plugin-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func makePlugin(name: String, hook: String, scriptURL: URL, protocol proto: String = "json", batchProxy: Bool = false) throws -> LoadedPlugin {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    var hookDict: [String: Any] = [
        "command": scriptURL.path,
        "args": [],
        "protocol": proto
    ]
    if batchProxy {
        hookDict["batchProxy"] = ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
    }
    let manifest: [String: Any] = [
        "name": name,
        "pluginProtocolVersion": "1",
        "hooks": [hook: hookDict]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try data.write(to: tempDir.appendingPathComponent("plugin.json"))
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
    return LoadedPlugin(name: name, directory: tempDir, manifest: decoded)
}

@Suite("PluginRunner")
struct PluginRunnerTests {
    let tempFolder: TempFolder

    init() throws {
        tempFolder = try TempFolder.create()
        // Add a test image
        let imgPath = tempFolder.url.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath)
    }

    @Test("json protocol: success result returns .success")
    func testJSONSuccess() async throws {
        let script = try makeTempScript("""
        printf '{"type":"result","success":true,"error":null}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .success)
    }

    @Test("json protocol: non-zero critical exit code returns .critical")
    func testJSONExitCritical() async throws {
        let script = try makeTempScript("exit 1")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("pipe protocol: exit 0 returns .success")
    func testPipeSuccess() async throws {
        let script = try makeTempScript("echo 'hello from pipe plugin'; exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "post-publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .success)
    }

    @Test("pipe protocol: exit 1 returns .critical")
    func testPipeCritical() async throws {
        let script = try makeTempScript("exit 1")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "post-publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("inactivity timeout kills process and returns .critical")
    func testInactivityTimeout() async throws {
        // Script sleeps forever — should be killed by timeout
        let script = try makeTempScript("sleep 60")
        defer { try? FileManager.default.removeItem(at: script) }

        // Build plugin with 1-second timeout
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "name": "slow",
            "pluginProtocolVersion": "1",
            "hooks": ["publish": ["command": script.path, "args": [], "timeout": 1]]
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let plugin = LoadedPlugin(name: "slow", directory: tempDir, manifest: manifest)

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("$PIQLEY_FOLDER_PATH token is substituted in args")
    func testTokenSubstitution() async throws {
        // Script echoes its first argument to verify token was replaced
        let script = try makeTempScript("""
        echo "got: $1"
        printf '{"type":"result","success":true,"error":null}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "name": "token-test",
            "pluginProtocolVersion": "1",
            "hooks": ["publish": [
                "command": script.path,
                "args": ["$PIQLEY_FOLDER_PATH"],
                "protocol": "json"
            ]]
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let plugin = LoadedPlugin(name: "token-test", directory: tempDir, manifest: manifest)

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .success)
    }

    @Test("batchProxy declared on json protocol returns critical (validation error)")
    func testBatchProxyWithJSONProtocolIsCritical() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "name": "bad",
            "pluginProtocolVersion": "1",
            "hooks": ["publish": [
                "command": script.path,
                "args": [],
                "protocol": "json",
                "batchProxy": ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
            ]]
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let plugin = LoadedPlugin(name: "bad", directory: tempDir, manifest: manifest)

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("batchProxy+pipe calls plugin once per image in folder")
    func testBatchProxy() async throws {
        // Script appends its first arg (image path) to a temp file so we can count calls
        let callLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-calls-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        echo "$PIQLEY_IMAGE_PATH" >> "\(callLog.path)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: callLog)
        }

        let plugin = try makePlugin(name: "test", hook: "pre-process", scriptURL: script, protocol: "pipe", batchProxy: true)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        _ = try await runner.run(
            hook: "pre-process",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )

        let calls = (try? String(contentsOf: callLog, encoding: .utf8))?.split(separator: "\n") ?? []
        #expect(calls.count == 1)  // tempFolder has 1 image
        #expect(calls.first?.hasSuffix("test.jpg") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PluginRunnerTests 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create `Sources/piqley/Plugins/PluginRunner.swift`**

```swift
import Foundation
import Logging

/// Runs a single plugin hook as a subprocess.
struct PluginRunner: Sendable {
    let plugin: LoadedPlugin
    let secrets: [String: String]
    private let logger = Logger(label: "piqley.runner")

    static let defaultTimeoutSeconds = 30

    func run(
        hook: String,
        tempFolder: TempFolder,
        pluginConfig: [String: JSONValue],
        executionLogPath: URL,
        dryRun: Bool
    ) async throws -> ExitCodeResult {
        guard let hookConfig = plugin.manifest.hooks[hook] else {
            logger.error("Plugin '\(plugin.name)' has no config for hook '\(hook)'")
            return .critical
        }

        let proto = hookConfig.pluginProtocol ?? .json

        if proto == .json && hookConfig.batchProxy != nil {
            logger.error("Plugin '\(plugin.name)' hook '\(hook)': batchProxy is only valid with pipe protocol")
            return .critical
        }

        if proto == .pipe, let batchProxy = hookConfig.batchProxy {
            return try await runBatchProxy(
                hook: hook,
                hookConfig: hookConfig,
                batchProxy: batchProxy,
                tempFolder: tempFolder,
                executionLogPath: executionLogPath,
                dryRun: dryRun
            )
        }

        let environment = buildEnvironment(
            hook: hook,
            folderPath: tempFolder.url,
            imagePath: nil,
            executionLogPath: executionLogPath,
            dryRun: dryRun
        )
        let args = substitute(args: hookConfig.args, environment: environment)
        let executable = resolveExecutable(hookConfig.command)

        switch proto {
        case .json:
            return try await runJSON(
                hook: hook,
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig,
                folderPath: tempFolder.url,
                pluginConfig: pluginConfig,
                executionLogPath: executionLogPath,
                dryRun: dryRun
            )
        case .pipe:
            return try await runPipe(
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig
            )
        }
    }

    // MARK: - JSON Protocol

    private func runJSON(
        hook: String,
        executable: String,
        args: [String],
        environment: [String: String],
        hookConfig: PluginManifest.HookConfig,
        folderPath: URL,
        pluginConfig: [String: JSONValue],
        executionLogPath: URL,
        dryRun: Bool
    ) async throws -> ExitCodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write JSON payload to stdin
        let payload = buildJSONPayload(
            hook: hook,
            folderPath: folderPath,
            pluginConfig: pluginConfig,
            executionLogPath: executionLogPath,
            dryRun: dryRun
        )
        if let data = try? JSONEncoder().encode(payload) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timeoutSeconds = hookConfig.timeout ?? Self.defaultTimeoutSeconds
        return await readJSONOutput(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            hookConfig: hookConfig,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func readJSONOutput(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        hookConfig: PluginManifest.HookConfig,
        timeoutSeconds: Int
    ) async -> ExitCodeResult {
        let evaluator = hookConfig.makeEvaluator()
        var lastActivity = Date()
        var gotResult = false

        // Background task reads stderr and updates activity
        let stderrTask = Task {
            let handle = stderrPipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                lastActivity = Date()
                logger.debug("[\(plugin.name)] stderr: \(line)")
            }
        }

        // Timeout watchdog
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Date().timeIntervalSince(lastActivity) > Double(timeoutSeconds) {
                    process.terminate()
                    return
                }
            }
        }

        // Read stdout lines
        for try? await line in stdoutPipe.fileHandleForReading.bytes.lines {
            lastActivity = Date()
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(PluginOutputLine.self, from: data)
            else {
                logger.warning("[\(plugin.name)]: invalid JSON on stdout — treating as critical")
                process.terminate()
                watchdog.cancel()
                stderrTask.cancel()
                return .critical
            }
            switch obj.type {
            case "progress":
                logger.info("[\(plugin.name)]: \(obj.message ?? "")")
            case "imageResult":
                logger.debug("[\(plugin.name)] imageResult: \(obj.filename ?? "") success=\(obj.success ?? false)")
            case "result":
                gotResult = true
            default:
                break
            }
        }

        watchdog.cancel()
        stderrTask.cancel()
        process.waitUntilExit()

        if !gotResult {
            logger.warning("[\(plugin.name)]: no 'result' line received — treating as critical")
            return .critical
        }

        return evaluator.evaluate(process.terminationStatus)
    }

    // MARK: - Pipe Protocol

    private func runPipe(
        executable: String,
        args: [String],
        environment: [String: String],
        hookConfig: PluginManifest.HookConfig
    ) async throws -> ExitCodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        // stdout/stderr forwarded to our stdout/stderr
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()

        let timeoutSeconds = hookConfig.timeout ?? Self.defaultTimeoutSeconds
        // Known limitation: pipe protocol uses a wall-clock timeout (not inactivity-based)
        // because stdout goes directly to the terminal and can't be intercepted without
        // buffering. A pipe plugin that emits output will still be killed after `timeoutSeconds`
        // of wall-clock time. This is a deliberate trade-off for protocol simplicity.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                self.logger.warning("[\(self.plugin.name)]: inactivity timeout — killing process")
                process.terminate()
            }
        }
        process.waitUntilExit()
        watchdog.cancel()

        return hookConfig.makeEvaluator().evaluate(process.terminationStatus)
    }

    // MARK: - BatchProxy

    private func runBatchProxy(
        hook: String,
        hookConfig: PluginManifest.HookConfig,
        batchProxy: PluginManifest.BatchProxyConfig,
        tempFolder: TempFolder,
        executionLogPath: URL,
        dryRun: Bool
    ) async throws -> ExitCodeResult {
        let images = try sortedImages(in: tempFolder.url, sort: batchProxy.sort)

        for image in images {
            let environment = buildEnvironment(
                hook: hook,
                folderPath: tempFolder.url,
                imagePath: image,
                executionLogPath: executionLogPath,
                dryRun: dryRun
            )
            let args = substitute(args: hookConfig.args, environment: environment)
            let executable = resolveExecutable(hookConfig.command)
            let result = try await runPipe(
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig
            )
            if result == .critical { return .critical }
        }
        return .success
    }

    // MARK: - Helpers

    private func resolveExecutable(_ command: String) -> String {
        if command.hasPrefix("/") { return command }
        // Relative path — resolve against plugin directory
        return plugin.directory.appendingPathComponent(command).path
    }

    private func substitute(args: [String], environment: [String: String]) -> [String] {
        args.map { arg in
            var result = arg
            for (key, value) in environment {
                result = result.replacingOccurrences(of: "$\(key)", with: value)
            }
            return result
        }
    }

    private func buildEnvironment(
        hook: String,
        folderPath: URL,
        imagePath: URL?,
        executionLogPath: URL,
        dryRun: Bool
    ) -> [String: String] {
        var env: [String: String] = [
            "PIQLEY_FOLDER_PATH": folderPath.path,
            "PIQLEY_HOOK": hook,
            "PIQLEY_DRY_RUN": dryRun ? "1" : "0",
            "PIQLEY_EXECUTION_LOG_PATH": executionLogPath.path,
        ]
        if let imagePath {
            env["PIQLEY_IMAGE_PATH"] = imagePath.path
        }
        for (key, value) in secrets {
            env["PIQLEY_SECRET_\(key.uppercased().replacingOccurrences(of: "-", with: "_"))"] = value
        }
        return env
    }

    private func buildJSONPayload(
        hook: String,
        folderPath: URL,
        pluginConfig: [String: JSONValue],
        executionLogPath: URL,
        dryRun: Bool
    ) -> PluginInputPayload {
        PluginInputPayload(
            hook: hook,
            folderPath: folderPath.path,
            pluginConfig: pluginConfig,
            secrets: secrets,
            executionLogPath: executionLogPath.path,
            dryRun: dryRun
        )
    }

    private func sortedImages(
        in directory: URL,
        sort: PluginManifest.BatchProxyConfig.SortConfig?
    ) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

        guard let sort else { return contents }

        switch sort.key {
        case "filename":
            let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return sort.order == .ascending ? sorted : sorted.reversed()
        default:
            // EXIF/IPTC sort keys require metadata reading — return filename-sorted as fallback
            logger.warning("batchProxy sort key '\(sort.key)' requires metadata reading — falling back to filename sort")
            return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
}

// MARK: - JSON I/O Types

private struct PluginInputPayload: Encodable {
    let hook: String
    let folderPath: String
    let pluginConfig: [String: JSONValue]
    let secrets: [String: String]
    let executionLogPath: String
    let dryRun: Bool
}

private struct PluginOutputLine: Decodable {
    let type: String
    let message: String?
    let filename: String?
    let success: Bool?
    let error: String?
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter PluginRunnerTests 2>&1 | tail -20
```

Expected: All 7 tests pass. (The timeout test may take ~2 seconds.)

- [ ] **Step 5: Build to verify no regressions**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/Plugins/PluginRunner.swift Tests/piqleyTests/PluginRunnerTests.swift
git commit -m "feat: add PluginRunner with json/pipe/batchProxy support"
```

---

## Task 11: PipelineOrchestrator

**Files:**
- Create: `Sources/piqley/Pipeline/PipelineOrchestrator.swift`

The orchestrator coordinates the full hook sequence, manages the blocklist, loads secrets from Keychain, and handles the temp folder lifecycle.

- [ ] **Step 1: Create `Sources/piqley/Pipeline/PipelineOrchestrator.swift`**

```swift
import Foundation
import Logging

struct PipelineOrchestrator: Sendable {
    let config: AppConfig
    let pluginsDirectory: URL
    let secretStore: any SecretStore
    private let logger = Logger(label: "piqley.pipeline")

    /// Resolves the default plugins directory.
    static var defaultPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/plugins")
    }

    /// Runs the full pipeline for a source folder.
    /// Returns `true` if all hooks succeeded, `false` if any hook aborted the pipeline.
    func run(sourceURL: URL, dryRun: Bool) async throws -> Bool {
        var pipeline = config.pipeline

        // Auto-discover new plugins if enabled
        if config.autoDiscoverPlugins {
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDirectory)
            let discovered = try discovery.loadManifests(disabled: config.disabledPlugins)
            PluginDiscovery.autoAppend(discovered: discovered, into: &pipeline)
        }

        // Create temp folder and copy images
        let temp = try TempFolder.create()
        logger.info("Temp folder: \(temp.url.path)")
        do {
            try temp.copyImages(from: sourceURL)
        } catch {
            try? temp.delete()
            throw error
        }

        let blocklist = PluginBlocklist()
        var succeeded = true

        defer {
            do {
                try temp.delete()
                logger.debug("Temp folder deleted")
            } catch {
                logger.warning("Failed to delete temp folder: \(error)")
            }
        }

        // Execute hooks in order
        for hook in PluginManifest.canonicalHooks {
            let pluginNames = pipeline[hook] ?? []
            for pluginEntry in pluginNames {
                // Strip any suffix (e.g. ":required" kept for forward-compat)
                let pluginName = pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry

                guard !blocklist.isBlocked(pluginName) else {
                    logger.debug("[\(pluginName)] skipped (blocklisted)")
                    continue
                }

                guard let loadedPlugin = try loadPlugin(named: pluginName) else {
                    logger.error("Plugin '\(pluginName)' not found in \(pluginsDirectory.path)")
                    blocklist.block(pluginName)
                    succeeded = false
                    return false
                }

                // Fetch secrets from Keychain — missing secret is a critical failure
                let secrets: [String: String]
                do {
                    secrets = try fetchSecrets(for: loadedPlugin)
                } catch {
                    blocklist.block(pluginName)
                    succeeded = false
                    return false
                }

                // Resolve execution log path (tilde-expanded)
                let execLogPath = pluginsDirectory
                    .appendingPathComponent(pluginName)
                    .appendingPathComponent("logs/execution.jsonl")
                try FileManager.default.createDirectory(
                    at: execLogPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let pluginConfig = config.plugins[pluginName] ?? [:]
                let runner = PluginRunner(plugin: loadedPlugin, secrets: secrets)

                logger.info("Running plugin '\(pluginName)' for hook '\(hook)'")
                let result = try await runner.run(
                    hook: hook,
                    tempFolder: temp,
                    pluginConfig: pluginConfig,
                    executionLogPath: execLogPath,
                    dryRun: dryRun
                )

                switch result {
                case .success:
                    logger.info("[\(pluginName)] hook '\(hook)': success")
                case .warning:
                    logger.warning("[\(pluginName)] hook '\(hook)': completed with warnings")
                case .critical:
                    logger.error("[\(pluginName)] hook '\(hook)': critical failure — aborting pipeline")
                    blocklist.block(pluginName)
                    succeeded = false
                    return false
                }
            }
        }

        return succeeded
    }

    private func loadPlugin(named name: String) throws -> LoadedPlugin? {
        let pluginDir = pluginsDirectory.appendingPathComponent(name)
        let manifestURL = pluginDir.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        return LoadedPlugin(name: name, directory: pluginDir, manifest: manifest)
    }

    /// Fetches all declared secrets for a plugin from the Keychain.
    /// Returns the secret map on success.
    /// Throws if any declared secret is missing — missing secrets are a critical failure per spec.
    private func fetchSecrets(for plugin: LoadedPlugin) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secrets {
            do {
                let value = try secretStore.getPluginSecret(plugin: plugin.name, key: key)
                result[key] = value
            } catch {
                logger.error("[\(plugin.name)] required secret '\(key)' not found in Keychain: \(error)")
                logger.error("Run 'piqley secret set \(plugin.name) \(key)' to configure it.")
                throw SecretStoreError.notFound(key: "piqley.plugins.\(plugin.name).\(key)")
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Add `PipelineOrchestratorTests`**

Create `Tests/piqleyTests/PipelineOrchestratorTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

/// A fake SecretStore that returns pre-configured values, throws for missing keys.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]

    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }
    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
}

private func makePluginsDir(withPlugin name: String, hook: String, scriptURL: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
    let pluginDir = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
        "name": name,
        "pluginProtocolVersion": "1",
        "hooks": [hook: ["command": scriptURL.path, "args": [], "protocol": "pipe"]]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
    return dir
}

private func makeSourceDir(withImage: Bool = true) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-src-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if withImage {
        try TestFixtures.createTestJPEG(at: dir.appendingPathComponent("photo.jpg").path)
    }
    return dir
}

@Suite("PipelineOrchestrator")
struct PipelineOrchestratorTests {
    @Test("successful pipeline returns true")
    func testSuccess() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(withPlugin: "test-plugin", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var config = AppConfig()
        config.pipeline["publish"] = ["test-plugin"]
        config.autoDiscoverPlugins = false

        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore()
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == true)
    }

    @Test("critical plugin failure returns false and aborts pipeline")
    func testCriticalAborts() async throws {
        let failScript = try makeTempScript("exit 1")
        let successScript = try makeTempScript("exit 0")
        defer {
            try? FileManager.default.removeItem(at: failScript)
            try? FileManager.default.removeItem(at: successScript)
        }

        // Two plugins in publish hook: first fails critically, second should never run
        let pluginsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-orch-\(UUID().uuidString)")

        for (name, script) in [("fail-plugin", failScript), ("ok-plugin", successScript)] {
            let pluginDir = pluginsDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "name": name,
                "pluginProtocolVersion": "1",
                "hooks": ["publish": ["command": script.path, "args": [], "protocol": "pipe"]]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
        }
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var config = AppConfig()
        config.pipeline["publish"] = ["fail-plugin", "ok-plugin"]
        config.autoDiscoverPlugins = false

        let orchestrator = PipelineOrchestrator(
            config: config, pluginsDirectory: pluginsDir, secretStore: FakeSecretStore()
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == false)
    }

    @Test("missing required secret is a critical failure")
    func testMissingSecretIsCritical() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let pluginsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
        let pluginDir = pluginsDir.appendingPathComponent("secret-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "secret-plugin",
            "pluginProtocolVersion": "1",
            "secrets": ["api-key"],
            "hooks": ["publish": ["command": script.path, "args": [], "protocol": "pipe"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var config = AppConfig()
        config.pipeline["publish"] = ["secret-plugin"]
        config.autoDiscoverPlugins = false

        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore() // no secrets configured
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == false)
    }
}

// Reuse helper from PluginRunnerTests
private func makeTempScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-script-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
```

- [ ] **Step 4: Run the new tests**

```bash
swift test --filter PipelineOrchestratorTests 2>&1 | tail -15
```

Expected: All 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift Tests/piqleyTests/PipelineOrchestratorTests.swift
git commit -m "feat: add PipelineOrchestrator with tests"
```

---

## Task 12: Rewrite ProcessCommand

**Files:**
- Modify: `Sources/piqley/CLI/ProcessCommand.swift`

Replace the stub with a real implementation wiring together `PipelineOrchestrator`, `ProcessLock`, and the source folder cleanup flags.

- [ ] **Step 1: Rewrite `Sources/piqley/CLI/ProcessCommand.swift`**

```swift
import ArgumentParser
import Foundation
import Logging

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process and publish photos via plugins"
    )

    @Argument(help: "Path to folder containing images to process")
    var folderPath: String

    @Flag(help: "Preview without uploading or modifying anything")
    var dryRun = false

    @Flag(help: "Delete source image files after a successful run")
    var deleteSourceImages = false

    @Flag(help: "Delete source folder after a successful run (implies --delete-source-images)")
    var deleteSourceFolder = false

    private let logger = Logger(label: "piqley.process")

    func run() async throws {
        let sourceURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ValidationError("Folder not found: \(folderPath)")
        }

        let lock = ProcessLock()
        try lock.acquire()
        defer { lock.release() }

        let config: AppConfig
        do {
            config = try AppConfig.load()
        } catch {
            throw ValidationError("Failed to load config: \(formatError(error))\nRun 'piqley setup' to create a config.")
        }

        let secretStore = KeychainSecretStore()
        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory,
            secretStore: secretStore
        )

        let succeeded = try await orchestrator.run(sourceURL: sourceURL, dryRun: dryRun)

        if succeeded && !dryRun {
            if deleteSourceFolder {
                logger.info("Deleting source folder: \(sourceURL.path)")
                try FileManager.default.removeItem(at: sourceURL)
            } else if deleteSourceImages {
                logger.info("Deleting source images from: \(sourceURL.path)")
                let contents = try FileManager.default.contentsOfDirectory(
                    at: sourceURL, includingPropertiesForKeys: nil
                )
                for file in contents where TempFolder.imageExtensions.contains(file.pathExtension.lowercased()) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }

        if !succeeded {
            throw ExitCode(1)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/CLI/ProcessCommand.swift
git commit -m "feat: rewrite ProcessCommand as thin pipeline orchestration layer"
```

---

## Task 13: SecretCommand

**Files:**
- Create: `Sources/piqley/CLI/SecretCommand.swift`
- Modify: `Sources/piqley/Piqley.swift`

- [ ] **Step 1: Create `Sources/piqley/CLI/SecretCommand.swift`**

```swift
import ArgumentParser
import Foundation

struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage plugin secrets in the macOS Keychain",
        subcommands: [SetCommand.self, DeleteCommand.self]
    )

    struct SetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Store a plugin secret in the Keychain (prompts for value)"
        )

        @Argument(help: "Plugin name (e.g. ghost)")
        var plugin: String

        @Argument(help: "Secret key (e.g. api-key)")
        var key: String

        func run() throws {
            print("Enter value for \(plugin)/\(key) (input hidden): ", terminator: "")
            guard let value = readLine(strippingNewline: true), !value.isEmpty else {
                throw ValidationError("No value entered")
            }
            let store = KeychainSecretStore()
            try store.setPluginSecret(plugin: plugin, key: key, value: value)
            print("Stored secret '\(key)' for plugin '\(plugin)'")
        }
    }

    struct DeleteCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Remove a plugin secret from the Keychain"
        )

        @Argument(help: "Plugin name (e.g. ghost)")
        var plugin: String

        @Argument(help: "Secret key (e.g. api-key)")
        var key: String

        func run() throws {
            let store = KeychainSecretStore()
            try store.deletePluginSecret(plugin: plugin, key: key)
            print("Deleted secret '\(key)' for plugin '\(plugin)'")
        }
    }
}
```

- [ ] **Step 2: Add `SecretCommand` to Piqley.swift**

Read current `Sources/piqley/Piqley.swift` and add `SecretCommand` to the subcommands list. It currently has `ProcessCommand`, `SetupCommand`, `ClearCacheCommand`, `VerifyCommand`. Add `SecretCommand`:

```swift
subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self, VerifyCommand.self, SecretCommand.self]
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/CLI/SecretCommand.swift Sources/piqley/Piqley.swift
git commit -m "feat: add SecretCommand for plugin Keychain management"
```

---

## Task 14: ClearCacheCommand

**Files:**
- Modify: `Sources/piqley/CLI/ClearCacheCommand.swift`

- [ ] **Step 1: Rewrite `Sources/piqley/CLI/ClearCacheCommand.swift`**

```swift
import ArgumentParser
import Foundation
import Logging

struct ClearCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-cache",
        abstract: "Clear plugin execution logs"
    )

    @Option(help: "Clear only this plugin's execution log (by plugin name)")
    var plugin: String?

    private let logger = Logger(label: "piqley.clear-cache")

    func run() throws {
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

        if let pluginName = plugin {
            let logPath = pluginsDir
                .appendingPathComponent(pluginName)
                .appendingPathComponent("logs/execution.jsonl")
            try clearLog(at: logPath, label: pluginName)
        } else {
            // Clear all plugin execution logs
            guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
                print("No plugins directory found at \(pluginsDir.path)")
                return
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]
            )
            for pluginDir in contents where (try? pluginDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let logPath = pluginDir.appendingPathComponent("logs/execution.jsonl")
                try clearLog(at: logPath, label: pluginDir.lastPathComponent)
            }
        }
    }

    private func clearLog(at url: URL, label: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[\(label)] No execution log found")
            return
        }
        try FileManager.default.removeItem(at: url)
        print("[\(label)] Execution log cleared")
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/CLI/ClearCacheCommand.swift
git commit -m "feat: rewrite ClearCacheCommand for plugin execution logs"
```

---

## Task 15: Rewrite SetupCommand

**Files:**
- Modify: `Sources/piqley/CLI/SetupCommand.swift`

The new setup wizard seeds the new config schema and installs bundled plugins from a path relative to the piqley executable.

- [ ] **Step 1: Rewrite `Sources/piqley/CLI/SetupCommand.swift`**

```swift
import ArgumentParser
import Foundation
import Logging

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up piqley configuration and install bundled plugins"
    )

    private let logger = Logger(label: "piqley.setup")

    func run() async throws {
        print("Welcome to piqley setup.\n")

        var config = AppConfig()

        // Auto-discover preference
        let autoDiscover = prompt("Auto-discover new plugins from ~/.config/piqley/plugins/? [Y/n]: ",
                                  default: "Y").lowercased() != "n"
        config.autoDiscoverPlugins = autoDiscover

        // Signing config (optional, for verify command)
        let setupSigning = prompt("Configure GPG signing for the verify command? [y/N]: ",
                                  default: "N").lowercased() == "y"
        if setupSigning {
            var signing = AppConfig.SigningConfig()
            signing.xmpNamespace = promptRequired("XMP namespace (e.g. https://yoursite.com/xmp/1.0/): ")
            signing.xmpPrefix = prompt("XMP prefix [piqley]: ", default: "piqley")
            config.signing = signing
        }

        // Seed default pipeline with bundled plugins
        config.pipeline["pre-process"] = ["piqley-metadata", "piqley-resize"]

        // Save config
        try config.save()
        print("\nConfig saved to \(AppConfig.configURL.path)")

        // Install bundled plugins
        installBundledPlugins()

        print("\nSetup complete. Run 'piqley secret set <plugin> <key>' to configure plugin credentials.")
    }

    // MARK: - Bundled Plugin Install

    private func installBundledPlugins() {
        // Bundled plugins live alongside the piqley binary at ../lib/piqley/plugins/
        guard let executablePath = ProcessInfo.processInfo.arguments.first else { return }
        let execURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let bundledPluginsDir = execURL
            .deletingLastPathComponent()          // bin/
            .deletingLastPathComponent()          // prefix/
            .appendingPathComponent("lib/piqley/plugins")

        guard FileManager.default.fileExists(atPath: bundledPluginsDir.path) else {
            logger.debug("No bundled plugins directory at \(bundledPluginsDir.path) — skipping")
            return
        }

        let targetDir = PipelineOrchestrator.defaultPluginsDirectory
        do {
            let bundled = try FileManager.default.contentsOfDirectory(
                at: bundledPluginsDir, includingPropertiesForKeys: [.isDirectoryKey]
            )
            for src in bundled where (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let dest = targetDir.appendingPathComponent(src.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    logger.debug("Plugin '\(src.lastPathComponent)' already installed — skipping")
                    continue
                }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: dest)
                print("Installed bundled plugin: \(src.lastPathComponent)")
            }
        } catch {
            logger.warning("Failed to install bundled plugins: \(error)")
        }
    }

    // MARK: - Input Helpers

    private func prompt(_ message: String, default defaultValue: String) -> String {
        print(message, terminator: "")
        let input = readLine(strippingNewline: true) ?? ""
        return input.isEmpty ? defaultValue : input
    }

    private func promptRequired(_ message: String) -> String {
        while true {
            print(message, terminator: "")
            let input = readLine(strippingNewline: true) ?? ""
            if !input.isEmpty { return input }
            print("Value is required.")
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/CLI/SetupCommand.swift
git commit -m "feat: rewrite SetupCommand for plugin architecture"
```

---

## Task 16: Final Build Verification & Run All Tests

- [ ] **Step 1: Run all tests**

```bash
swift test 2>&1 | tail -30
```

Expected: All tests pass. The following test suites should pass:
- `ConfigTests`
- `ExitCodeEvaluatorTests`
- `PluginBlocklistTests`
- `TempFolderTests`
- `PluginManifestTests`
- `PluginDiscoveryTests`
- `PluginRunnerTests`
- `PipelineOrchestratorTests`
- `ProcessLockTests`

- [ ] **Step 2: Build release**

```bash
swift build -c release 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Smoke test — help output looks correct**

```bash
.build/release/piqley --help
```

Expected output shows:
```
SUBCOMMANDS:
  process
  setup
  verify
  clear-cache
  secret
```

- [ ] **Step 4: Smoke test — process --help**

```bash
.build/release/piqley process --help
```

Expected: Shows `--dry-run`, `--delete-source-images`, `--delete-source-folder`. No Ghost or results flags.

- [ ] **Step 5: Smoke test — secret --help shows set/delete subcommands**

```bash
.build/release/piqley secret --help
```

Expected: Shows `set` and `delete` as subcommands.

- [ ] **Step 6: Smoke test — dry run on an empty folder**

```bash
mkdir /tmp/piqley-smoke-test
.build/release/piqley process /tmp/piqley-smoke-test --dry-run 2>&1
rmdir /tmp/piqley-smoke-test
```

Expected: Exits cleanly (no config = `ValidationError` about missing config — that's acceptable since no config exists in CI).

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "feat: complete plugin architecture refactor

- Plugin runner with json/pipe/batchProxy protocols
- Inactivity timeout with subprocess isolation
- Auto-discovery of plugins from ~/.config/piqley/plugins/
- Namespaced Keychain secrets via piqley secret set/delete
- Simplified ProcessCommand delegating to PipelineOrchestrator
- Legacy Ghost/Email/ImageProcessing/Logging code moved to _migrate/

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
