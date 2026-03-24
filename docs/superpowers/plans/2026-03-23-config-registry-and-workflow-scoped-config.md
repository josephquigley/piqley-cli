# Config Registry and Workflow-Scoped Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace static JSON config/secret declarations with a programmatic ConfigRegistry DSL and restructure config/secret storage to support workflow-scoped overrides with shared secret aliases.

**Architecture:** ConfigRegistry DSL in piqley-plugin-sdk generates config-entries.json at build time (parallel to stage file generation). CLI stores base config per plugin at ~/.config/piqley/config/, with workflow JSON overrides merged at runtime. Secrets use alias indirection into the keychain.

**Tech Stack:** Swift 6, Swift Testing framework, PiqleyCore, PiqleyPluginSDK, ArgumentParser

**Spec:** `docs/superpowers/specs/2026-03-23-config-registry-and-workflow-scoped-config-design.md`

---

## Parallelization Notes

Tasks are organized by repo. Within each repo, tasks are sequential. However, the two repo tracks (SDK and CLI) are **fully independent** and can run in parallel on separate worktrees.

**Track A (piqley-plugin-sdk):** Tasks 1-4
**Track B (piqley-cli):** Tasks 5-12

---

## Track A: piqley-plugin-sdk

### Task 1: ConfigRegistry DSL and builder structs

**Files:**
- Create: `swift/PiqleyPluginSDK/Builders/ConfigRegistryBuilder.swift`
- Test: `swift/Tests/ConfigRegistryTests.swift`

- [ ] **Step 1: Write failing tests for Config, Secret, and ConfigRegistry**

```swift
import Testing
import Foundation
import PiqleyCore
@testable import PiqleyPluginSDK

@Suite("ConfigRegistry")
struct ConfigRegistryTests {
    @Test("Config creates a value ConfigEntry")
    func configCreatesValueEntry() {
        let config = Config("siteUrl", type: .string, default: .string("https://example.com"))
        #expect(config.entry == ConfigEntry.value(key: "siteUrl", type: .string, value: .string("https://example.com")))
    }

    @Test("Secret creates a secret ConfigEntry")
    func secretCreatesSecretEntry() {
        let secret = Secret("API_KEY", type: .string)
        #expect(secret.entry == ConfigEntry.secret(secretKey: "API_KEY", type: .string))
    }

    @Test("ConfigRegistry collects entries from builder")
    func registryCollectsEntries() {
        let registry = ConfigRegistry {
            Config("quality", type: .int, default: .int(85))
            Secret("TOKEN", type: .string)
        }
        #expect(registry.entries.count == 2)
        #expect(registry.entries[0] == ConfigEntry.value(key: "quality", type: .int, value: .int(85)))
        #expect(registry.entries[1] == ConfigEntry.secret(secretKey: "TOKEN", type: .string))
    }

    @Test("ConfigRegistry writes config-entries.json")
    func writeConfigEntries() throws {
        let registry = ConfigRegistry {
            Config("url", type: .string, default: .string("https://example.com"))
            Secret("KEY", type: .string)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try registry.writeConfigEntries(to: dir)

        let file = dir.appendingPathComponent("config-entries.json")
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode([ConfigEntry].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0] == ConfigEntry.value(key: "url", type: .string, value: .string("https://example.com")))
        #expect(decoded[1] == ConfigEntry.secret(secretKey: "KEY", type: .string))
    }

    @Test("Empty ConfigRegistry writes empty array")
    func emptyRegistryWritesEmptyArray() throws {
        let registry = ConfigRegistry {}
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try registry.writeConfigEntries(to: dir)

        let data = try Data(contentsOf: dir.appendingPathComponent("config-entries.json"))
        let decoded = try JSONDecoder().decode([ConfigEntry].self, from: data)
        #expect(decoded.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ConfigRegistryTests`
Expected: Compilation errors (types don't exist yet)

- [ ] **Step 3: Implement ConfigRegistry, Config, Secret, and ConfigComponentBuilder**

Create `swift/PiqleyPluginSDK/Builders/ConfigRegistryBuilder.swift`:

```swift
import Foundation
import PiqleyCore

// MARK: - ConfigComponent protocol

public protocol ConfigComponent: Sendable {}

// MARK: - Config

public struct Config: ConfigComponent {
    let entry: ConfigEntry
    public init(_ key: String, type: ConfigValueType, default value: JSONValue) {
        self.entry = .value(key: key, type: type, value: value)
    }
}

// MARK: - Secret

public struct Secret: ConfigComponent {
    let entry: ConfigEntry
    public init(_ key: String, type: ConfigValueType) {
        self.entry = .secret(secretKey: key, type: type)
    }
}

// MARK: - ConfigComponentBuilder

@resultBuilder
public enum ConfigComponentBuilder {
    public static func buildBlock(_ components: (any ConfigComponent)...) -> [any ConfigComponent] {
        components
    }
    public static func buildExpression(_ expression: any ConfigComponent) -> any ConfigComponent {
        expression
    }
}

// MARK: - ConfigRegistry

public struct ConfigRegistry: Sendable {
    public let entries: [ConfigEntry]

    public init(@ConfigComponentBuilder _ builder: () -> [any ConfigComponent]) {
        self.entries = builder().compactMap { component in
            switch component {
            case let config as Config:
                return config.entry
            case let secret as Secret:
                return secret.entry
            default:
                return nil
            }
        }
    }

    public func writeConfigEntries(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(
            to: directory.appendingPathComponent("config-entries.json"),
            options: .atomic
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ConfigRegistryTests`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```
feat: add ConfigRegistry DSL with Config and Secret builder structs
```

### Task 2: Rename piqley-stage-gen to piqley-manifest-gen in template

**Files:**
- Modify: `templates/swift/Package.swift`
- Rename: `templates/swift/Sources/StageGen/` -> `templates/swift/Sources/ManifestGen/`
- Modify: `templates/swift/Sources/ManifestGen/main.swift` (formerly StageGen)
- Modify: `templates/swift/piqley-build.sh`
- Modify: `templates/swift/Sources/PluginHooks/Hooks.swift`

- [ ] **Step 1: Rename StageGen directory to ManifestGen**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
mv templates/swift/Sources/StageGen templates/swift/Sources/ManifestGen
```

- [ ] **Step 2: Update Package.swift template target name**

In `templates/swift/Package.swift`, change the executable target from:
```swift
.executableTarget(
    name: "piqley-stage-gen",
    dependencies: ["PluginHooks"],
    path: "Sources/StageGen"
),
```
to:
```swift
.executableTarget(
    name: "piqley-manifest-gen",
    dependencies: ["PluginHooks"],
    path: "Sources/ManifestGen"
),
```

- [ ] **Step 3: Update ManifestGen/main.swift to also write config entries**

```swift
import Foundation
import PluginHooks

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("Usage: piqley-manifest-gen <output-directory>\n".utf8))
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try pluginRegistry.writeStageFiles(to: outputDir)
try pluginConfig.writeConfigEntries(to: outputDir)
```

- [ ] **Step 4: Update template Hooks.swift to export pluginConfig**

Add an empty ConfigRegistry alongside the existing HookRegistry:

```swift
import PiqleyPluginSDK
import PiqleyCore

extension PluginDirectory {
    static let pluginBinary = "\(bin)/__PLUGIN_PACKAGE_NAME__"
}

public let pluginRegistry = HookRegistry { r in
    r.register(StandardHook.self) { hook in
        switch hook {
        case .pipelineStart:
            return nil
        case .preProcess:
            return nil
        case .postProcess:
            return nil
        case .publish:
            return nil
        case .postPublish:
            return nil
        case .pipelineFinished:
            return nil
        }
    }
}

public let pluginConfig = ConfigRegistry {
}
```

- [ ] **Step 5: Update piqley-build.sh to detect and run piqley-manifest-gen**

Replace the stage file generation section. Change:
```bash
if "$SWIFT" package describe --type json 2>/dev/null | grep -q '"name".*:.*"piqley-stage-gen"'; then
    echo "Generating stage files..."
    "$SWIFT" build -c release --product piqley-stage-gen
    .build/release/piqley-stage-gen .
    echo ""
else
    echo "Warning: No piqley-stage-gen target found. Stage files will not be auto-generated."
    echo "Update your project layout to the latest SDK template for automatic stage generation."
    echo ""
fi
```
to:
```bash
if "$SWIFT" package describe --type json 2>/dev/null | grep -q '"name".*:.*"piqley-manifest-gen"'; then
    echo "Generating manifest data..."
    "$SWIFT" build -c release --product piqley-manifest-gen
    .build/release/piqley-manifest-gen .
    echo ""
else
    echo "Warning: No piqley-manifest-gen target found. Stage files and config entries will not be auto-generated."
    echo "Update your project layout to the latest SDK template for automatic generation."
    echo ""
fi
```

- [ ] **Step 6: Update CHANGELOG.md**

Add under `### Changed`:
- Renamed `piqley-stage-gen` to `piqley-manifest-gen`; now generates both stage files and `config-entries.json`

- [ ] **Step 7: Commit**

```
feat: rename piqley-stage-gen to piqley-manifest-gen, generate config-entries.json
```

### Task 3: Packager reads config-entries.json

**Files:**
- Modify: `swift/PiqleyPluginSDK/Packager.swift`
- Modify: `swift/Tests/PackagerTests.swift`

- [ ] **Step 1: Write failing test for Packager reading config-entries.json**

Add to PackagerTests.swift:

```swift
@Test("Packager uses config-entries.json for manifest config")
func packageUsesConfigEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Write build manifest (no config field)
    let manifest = BuildManifest(
        identifier: "com.test.plugin",
        pluginName: "Test Plugin",
        pluginSchemaVersion: "1",
        bin: ["macos-arm64": ["bin/test"]],
        data: [:]
    )
    let manifestData = try JSONEncoder().encode(manifest)
    try manifestData.write(to: dir.appendingPathComponent("piqley-build-manifest.json"))

    // Create bin file
    let binDir = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    try Data("binary".utf8).write(to: binDir.appendingPathComponent("test"))

    // Write config-entries.json
    let entries: [ConfigEntry] = [
        .value(key: "url", type: .string, value: .string("https://example.com")),
        .secret(secretKey: "API_KEY", type: .string),
    ]
    let entriesData = try JSONEncoder().encode(entries)
    try entriesData.write(to: dir.appendingPathComponent("config-entries.json"))

    let output = try Packager.package(directory: dir)
    defer { try? FileManager.default.removeItem(at: output) }

    // Extract and verify manifest.json has config from config-entries.json
    let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractDir) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", output.path, "-d", extractDir.path]
    try process.run()
    process.waitUntilExit()

    let pluginManifestData = try Data(contentsOf: extractDir
        .appendingPathComponent("Test Plugin")
        .appendingPathComponent(PluginFile.manifest))
    let pluginManifest = try JSONDecoder().decode(PluginManifest.self, from: pluginManifestData)
    #expect(pluginManifest.config.count == 2)
    #expect(pluginManifest.config[0] == .value(key: "url", type: .string, value: .string("https://example.com")))
    #expect(pluginManifest.config[1] == .secret(secretKey: "API_KEY", type: .string))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter "packageUsesConfigEntries"`
Expected: FAIL (Packager doesn't read config-entries.json yet)

- [ ] **Step 3: Update Packager to read config-entries.json**

In `Packager.swift`, after copying stage files and before copying bin files, add config-entries.json loading. Replace the `toPluginManifest()` call to inject the loaded config:

```swift
// Load config entries from config-entries.json (generated by piqley-manifest-gen)
let configEntriesURL = directory.appendingPathComponent("config-entries.json")
let configEntries: [ConfigEntry]
if fm.fileExists(atPath: configEntriesURL.path) {
    let configData = try Data(contentsOf: configEntriesURL)
    configEntries = try JSONDecoder().decode([ConfigEntry].self, from: configData)
} else {
    configEntries = []
}
```

Update the `toPluginManifest()` call to use the loaded entries instead of `BuildManifest.config`. Modify `toPluginManifest()` to accept an optional config override parameter:

```swift
public func toPluginManifest(configOverride: [ConfigEntry]? = nil) throws -> PluginManifest {
    let semver: SemanticVersion? = try pluginVersion.map { try SemanticVersion($0) }
    return PluginManifest(
        identifier: identifier,
        name: pluginName,
        description: description,
        pluginSchemaVersion: pluginSchemaVersion,
        pluginVersion: semver,
        config: configOverride ?? config ?? [],
        setup: setup,
        dependencies: dependencies,
        supportedFormats: supportedFormats,
        conversionFormat: conversionFormat,
        supportedPlatforms: Array(bin.keys).sorted()
    )
}
```

In Packager.package(), pass the loaded config:
```swift
let pluginManifest = try buildManifest.toPluginManifest(configOverride: configEntries.isEmpty ? nil : configEntries)
```

Also remove the `config.json` sidecar creation from the Packager (remove the block that copies or creates config.json).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter PackagerTests`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```
feat: Packager reads config-entries.json for manifest config
```

### Task 4: Update CHANGELOG, tag, and push SDK

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update CHANGELOG with all changes**

Ensure all new entries are under `## Unreleased` in the appropriate sections.

- [ ] **Step 2: Commit, merge to main, tag, and push**

Tag as next minor version after current (check latest tag first).

---

## Track B: piqley-cli

### Task 5: BasePluginConfig type

**Files:**
- Create: `Sources/piqley/Config/BasePluginConfig.swift`
- Create: `Tests/piqleyTests/BasePluginConfigTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import piqley

@Suite("BasePluginConfig")
struct BasePluginConfigTests {
    @Test("Encodes and decodes with values and secrets")
    func roundTrip() throws {
        let config = BasePluginConfig(
            values: ["url": .string("https://example.com"), "quality": .int(85)],
            secrets: ["API_KEY": "my-plugin-API_KEY"],
            isSetUp: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BasePluginConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("Decodes with empty values and secrets")
    func decodesEmpty() throws {
        let json = Data(#"{"values":{},"secrets":{}}"#.utf8)
        let config = try JSONDecoder().decode(BasePluginConfig.self, from: json)
        #expect(config.values.isEmpty)
        #expect(config.secrets.isEmpty)
        #expect(config.isSetUp == nil)
    }

    @Test("Merges workflow overrides on top of base")
    func mergeOverrides() {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com"), "quality": .int(85)],
            secrets: ["API_KEY": "prod-key"],
            isSetUp: true
        )
        let overrides = WorkflowPluginConfig(
            values: ["url": .string("https://staging.com")],
            secrets: ["API_KEY": "staging-key"]
        )
        let merged = base.merging(overrides)
        #expect(merged.values["url"] == .string("https://staging.com"))
        #expect(merged.values["quality"] == .int(85))
        #expect(merged.secrets["API_KEY"] == "staging-key")
    }

    @Test("Merge with nil overrides returns base values")
    func mergeNilOverrides() {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com")],
            secrets: ["API_KEY": "prod-key"],
            isSetUp: true
        )
        let overrides = WorkflowPluginConfig(values: nil, secrets: nil)
        let merged = base.merging(overrides)
        #expect(merged.values["url"] == .string("https://prod.com"))
        #expect(merged.secrets["API_KEY"] == "prod-key")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BasePluginConfigTests`
Expected: Compilation errors

- [ ] **Step 3: Implement BasePluginConfig and WorkflowPluginConfig**

Create `Sources/piqley/Config/BasePluginConfig.swift`:

```swift
import Foundation
import PiqleyCore

struct BasePluginConfig: Codable, Sendable, Equatable {
    var values: [String: JSONValue]
    var secrets: [String: String]
    var isSetUp: Bool?

    init(
        values: [String: JSONValue] = [:],
        secrets: [String: String] = [:],
        isSetUp: Bool? = nil
    ) {
        self.values = values
        self.secrets = secrets
        self.isSetUp = isSetUp
    }

    func merging(_ overrides: WorkflowPluginConfig) -> BasePluginConfig {
        var merged = self
        if let overrideValues = overrides.values {
            merged.values.merge(overrideValues) { _, new in new }
        }
        if let overrideSecrets = overrides.secrets {
            merged.secrets.merge(overrideSecrets) { _, new in new }
        }
        return merged
    }
}

struct WorkflowPluginConfig: Codable, Sendable, Equatable {
    var values: [String: JSONValue]?
    var secrets: [String: String]?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BasePluginConfigTests`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```
feat: add BasePluginConfig and WorkflowPluginConfig types
```

### Task 6: SecretStore.list() method

**Files:**
- Modify: `Sources/piqley/Secrets/SecretStore.swift`
- Modify: `Sources/piqley/Secrets/KeychainSecretStore.swift`
- Modify: `Sources/piqley/Secrets/FileSecretStore.swift`
- Create: `Tests/piqleyTests/SecretStoreTests.swift`

- [ ] **Step 1: Write failing test for list()**

```swift
import Testing
import Foundation
@testable import piqley

@Suite("SecretStore list")
struct SecretStoreListTests {
    @Test("FileSecretStore lists all stored keys")
    func fileStoreListsKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileSecretStore(directory: dir)
        try store.set(key: "alpha", value: "a")
        try store.set(key: "beta", value: "b")

        let keys = try store.list()
        #expect(keys.sorted() == ["alpha", "beta"])
    }

    @Test("FileSecretStore list returns empty for no secrets")
    func fileStoreListEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileSecretStore(directory: dir)
        let keys = try store.list()
        #expect(keys.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SecretStoreListTests`
Expected: Compilation errors (list() doesn't exist)

- [ ] **Step 3: Add list() to SecretStore protocol and implementations**

In `SecretStore.swift`, add to the protocol:
```swift
func list() throws -> [String]
```

In `FileSecretStore.swift`, implement:
```swift
func list() throws -> [String] {
    let url = directory.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    let data = try Data(contentsOf: url)
    let dict = try JSONDecoder().decode([String: String].self, from: data)
    return Array(dict.keys)
}
```

In `KeychainSecretStore.swift`, implement:
```swift
func list() throws -> [String] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        return []
    }
    guard status == errSecSuccess, let items = result as? [[String: Any]] else {
        throw SecretStoreError.keychainError(status)
    }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
}
```

Update any existing MockSecretStore / FakeSecretStore in test files to implement `list()`:
```swift
func list() throws -> [String] {
    Array(secrets.keys)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SecretStoreListTests`
Expected: All 2 tests PASS

- [ ] **Step 5: Commit**

```
feat: add list() to SecretStore protocol for enumerating secrets
```

### Task 7: Add config field to Workflow struct

**Files:**
- Modify: `Sources/piqley/Config/Workflow.swift`
- Modify: `Tests/piqleyTests/` (any tests that create Workflow instances)

- [ ] **Step 1: Add config field to Workflow**

In `Workflow.swift`, add:
```swift
/// Per-plugin config and secret overrides for this workflow.
var config: [String: WorkflowPluginConfig] = [:]
```

Update `Workflow.empty()` to include the config field.

- [ ] **Step 2: Update all test code that creates Workflow instances**

Search for `Workflow(` and `Workflow.empty(` in tests and add the `config` parameter where needed.

- [ ] **Step 3: Run full test suite to verify nothing breaks**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```
feat: add config field to Workflow for per-plugin overrides
```

### Task 8: BasePluginConfigStore for reading/writing base configs

**Files:**
- Create: `Sources/piqley/Config/BasePluginConfigStore.swift`
- Create: `Tests/piqleyTests/BasePluginConfigStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("BasePluginConfigStore")
struct BasePluginConfigStoreTests {
    @Test("Saves and loads base config")
    func saveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BasePluginConfigStore(directory: dir)
        let config = BasePluginConfig(
            values: ["url": .string("https://example.com")],
            secrets: ["API_KEY": "my-alias"],
            isSetUp: true
        )
        try store.save(config, for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == config)
    }

    @Test("Load returns nil for missing config")
    func loadMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BasePluginConfigStore(directory: dir)
        let loaded = try store.load(for: "com.test.missing")
        #expect(loaded == nil)
    }

    @Test("Delete removes config file")
    func deleteConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BasePluginConfigStore(directory: dir)
        let config = BasePluginConfig(values: ["k": .string("v")], secrets: [:])
        try store.save(config, for: "com.test.plugin")
        try store.delete(for: "com.test.plugin")
        let loaded = try store.load(for: "com.test.plugin")
        #expect(loaded == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BasePluginConfigStoreTests`
Expected: Compilation errors

- [ ] **Step 3: Implement BasePluginConfigStore**

```swift
import Foundation

struct BasePluginConfigStore: Sendable {
    let directory: URL

    func save(_ config: BasePluginConfig, for pluginIdentifier: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL(for: pluginIdentifier), options: .atomic)
    }

    func load(for pluginIdentifier: String) throws -> BasePluginConfig? {
        let url = fileURL(for: pluginIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BasePluginConfig.self, from: data)
    }

    func delete(for pluginIdentifier: String) throws {
        let url = fileURL(for: pluginIdentifier)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for pluginIdentifier: String) -> URL {
        directory.appendingPathComponent("\(pluginIdentifier).json")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BasePluginConfigStoreTests`
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```
feat: add BasePluginConfigStore for per-plugin config persistence
```

### Task 9: Config resolution (merging base + workflow + secret lookup)

**Files:**
- Create: `Sources/piqley/Config/ConfigResolver.swift`
- Create: `Tests/piqleyTests/ConfigResolverTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("ConfigResolver")
struct ConfigResolverTests {
    @Test("Resolves config with no workflow overrides")
    func noOverrides() throws {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com")],
            secrets: ["API_KEY": "prod-key"]
        )
        let secrets = MockSecretStore()
        try secrets.set(key: "prod-key", value: "secret123")

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: nil,
            secretStore: secrets
        )
        #expect(resolved.values["url"] == .string("https://prod.com"))
        #expect(resolved.secrets["API_KEY"] == "secret123")
    }

    @Test("Workflow overrides replace base values")
    func withOverrides() throws {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com"), "quality": .int(85)],
            secrets: ["API_KEY": "prod-key"]
        )
        let overrides = WorkflowPluginConfig(
            values: ["url": .string("https://staging.com")],
            secrets: ["API_KEY": "staging-key"]
        )
        let secrets = MockSecretStore()
        try secrets.set(key: "staging-key", value: "staging-secret")

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: overrides,
            secretStore: secrets
        )
        #expect(resolved.values["url"] == .string("https://staging.com"))
        #expect(resolved.values["quality"] == .int(85))
        #expect(resolved.secrets["API_KEY"] == "staging-secret")
    }

    @Test("Builds environment variables with correct prefixes")
    func environmentVariables() throws {
        let base = BasePluginConfig(
            values: ["site-url": .string("https://example.com")],
            secrets: ["API_KEY": "key-alias"]
        )
        let secrets = MockSecretStore()
        try secrets.set(key: "key-alias", value: "secret-value")

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: nil,
            secretStore: secrets
        )
        let env = resolved.toEnvironment()
        #expect(env["PIQLEY_CONFIG_SITE_URL"] == "https://example.com")
        #expect(env["PIQLEY_SECRET_API_KEY"] == "secret-value")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigResolverTests`
Expected: Compilation errors

- [ ] **Step 3: Implement ConfigResolver**

```swift
import Foundation
import PiqleyCore

struct ResolvedPluginConfig: Sendable {
    let values: [String: JSONValue]
    let secrets: [String: String]

    func toEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in values {
            let envKey = "PIQLEY_CONFIG_\(Self.sanitizeKey(key))"
            env[envKey] = value.stringRepresentation
        }
        for (key, value) in secrets {
            let envKey = "PIQLEY_SECRET_\(Self.sanitizeKey(key))"
            env[envKey] = value
        }
        return env
    }

    static func sanitizeKey(_ key: String) -> String {
        key.uppercased()
            .replacing("-", with: "_")
            .replacing(".", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

enum ConfigResolver {
    static func resolve(
        base: BasePluginConfig,
        workflowOverrides: WorkflowPluginConfig?,
        secretStore: any SecretStore
    ) throws -> ResolvedPluginConfig {
        let merged: BasePluginConfig
        if let overrides = workflowOverrides {
            merged = base.merging(overrides)
        } else {
            merged = base
        }

        var resolvedSecrets: [String: String] = [:]
        for (key, alias) in merged.secrets {
            resolvedSecrets[key] = try secretStore.get(key: alias)
        }

        return ResolvedPluginConfig(
            values: merged.values,
            secrets: resolvedSecrets
        )
    }
}
```

Also add `stringRepresentation` to `JSONValue` if it doesn't exist (check first). It should convert JSONValue to a string for env var use.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigResolverTests`
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```
feat: add ConfigResolver for merging base config with workflow overrides
```

### Task 10: Update PluginSetupScanner for new config layout

**Files:**
- Modify: `Sources/piqley/Plugins/PluginSetupScanner.swift`
- Modify: `Tests/piqleyTests/PluginSetupScannerTests.swift`

- [ ] **Step 1: Update PluginSetupScanner to write BasePluginConfig**

Refactor the scanner to:
1. Write config values to a `BasePluginConfig` instead of the plugin's `config.json`
2. Generate default secret aliases as `<plugin-identifier>-<secret-key>`
3. Store secrets in keychain using the alias as the key
4. Write alias mappings to `BasePluginConfig.secrets`
5. Accept a `BasePluginConfigStore` dependency

- [ ] **Step 2: Update existing tests to use new types**

Adjust test expectations to check BasePluginConfig output instead of config.json.

- [ ] **Step 3: Run tests to verify they pass**

Run: `swift test --filter PluginSetupScannerTests`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```
refactor: PluginSetupScanner writes BasePluginConfig instead of config.json sidecar
```

### Task 11: piqley workflow config command

**Files:**
- Create: `Sources/piqley/CLI/WorkflowConfigCommand.swift`
- Create: `Tests/piqleyTests/WorkflowConfigCommandTests.swift`

- [ ] **Step 1: Write failing tests for flag-based mode**

Test --set and --set-secret flags write to workflow JSON correctly.

- [ ] **Step 2: Implement WorkflowConfigCommand**

Using ArgumentParser, create a subcommand under `piqley workflow`:
```
piqley workflow config <workflow-name> <plugin-identifier> [--set key=value] [--set-secret KEY=alias]
```

Interactive mode (no flags): prompt through each config value and secret alias.
Flag mode: set individual overrides.

- [ ] **Step 3: Register command in the workflow command group**

- [ ] **Step 4: Run tests**

Run: `swift test --filter WorkflowConfigCommandTests`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```
feat: add piqley workflow config command with interactive and flag modes
```

### Task 12: Secret cleanup (workflow delete + prune command)

**Files:**
- Create: `Sources/piqley/CLI/SecretPruneCommand.swift`
- Modify: `Sources/piqley/CLI/WorkflowDeleteCommand.swift` (or equivalent)
- Create: `Tests/piqleyTests/SecretPruneTests.swift`

- [ ] **Step 1: Write failing tests for secret pruning**

Test that prune identifies and removes orphaned secrets by scanning base configs and workflow files.

- [ ] **Step 2: Implement SecretPruner utility**

A shared utility that:
1. Scans all base config files for secret aliases
2. Scans all workflow files for secret alias overrides
3. Collects the union of all referenced aliases
4. Lists all secrets from the secret store
5. Deletes any secret not in the referenced set

- [ ] **Step 3: Add piqley secret prune command**

- [ ] **Step 4: Wire secret pruning into workflow delete**

After deleting a workflow, call the pruner.

- [ ] **Step 5: Run tests**

Run: `swift test --filter SecretPruneTests`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```
feat: add secret pruning on workflow delete and piqley secret prune command
```

### Task 13: Update plugin uninstall to clean up base config

**Files:**
- Modify: `Sources/piqley/CLI/PluginUninstallCommand.swift`

- [ ] **Step 1: After plugin directory deletion, also delete base config file**

Add a call to `BasePluginConfigStore.delete(for: pluginIdentifier)` after the plugin directory is removed.

- [ ] **Step 2: Run secret pruner after uninstall to clean up orphaned aliases**

- [ ] **Step 3: Run tests**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```
feat: plugin uninstall deletes base config and prunes orphaned secrets
```

### Task 14: Migration from config.json sidecar

**Files:**
- Create: `Sources/piqley/Config/ConfigMigrator.swift`
- Create: `Tests/piqleyTests/ConfigMigratorTests.swift`

- [ ] **Step 1: Write failing tests for migration**

Test that:
1. Old config.json values are migrated to BasePluginConfig
2. Old keychain secrets are re-keyed to alias format
3. Old config.json is deleted after migration
4. Migration is skipped if base config already exists

- [ ] **Step 2: Implement ConfigMigrator**

```swift
enum ConfigMigrator {
    static func migrateIfNeeded(
        pluginsDirectory: URL,
        configStore: BasePluginConfigStore,
        secretStore: any SecretStore
    ) throws {
        // For each plugin with a config.json but no base config:
        // 1. Read old config.json values
        // 2. Read secret keys from manifest
        // 3. Re-key secrets from piqley.plugins.<id>.<key> to <id>-<key>
        // 4. Write base config with values + alias mappings
        // 5. Delete old config.json
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter ConfigMigratorTests`
Expected: All tests PASS

- [ ] **Step 4: Wire migration into CLI startup**

Call `ConfigMigrator.migrateIfNeeded()` early in commands that read plugin config.

- [ ] **Step 5: Commit**

```
feat: add config migration from config.json sidecar to base config layout
```

### Task 15: Remove old config.json sidecar code

**Files:**
- Modify: `Sources/piqley/Plugins/PluginConfig.swift` (or remove if fully replaced)
- Modify: any code that reads/writes the old config.json

- [ ] **Step 1: Find and remove all references to the old PluginConfig/config.json pattern**

- [ ] **Step 2: Run full test suite**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```
refactor: remove old config.json sidecar code
```
