# Plugin Setup Stage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable plugins to declare config schemas and optional setup binaries in their manifest, with piqley driving interactive setup and persisting state in a per-plugin config sidecar.

**Architecture:** Plugins declare config entries (values + secrets) and optional setup commands in `manifest.json` (renamed from `plugin.json`). Piqley scans plugins, prompts for missing config values, validates keychain secrets, and runs setup binaries. Resolved state lives in a `config.json` sidecar per plugin. The central `AppConfig.plugins` dictionary is removed.

**Tech Stack:** Swift, ArgumentParser, Keychain Services, Foundation (Process, JSONEncoder/Decoder)

**Spec:** `docs/superpowers/specs/2026-03-17-plugin-setup-stage-design.md`

---

## File Structure

### New Files
- `Sources/piqley/Plugins/PluginConfigEntry.swift` — `ConfigEntry` enum (value vs secret shapes) + `SetupConfig` struct
- `Sources/piqley/Plugins/PluginConfig.swift` — `PluginConfig` model for the `config.json` sidecar (values dict + isSetUp flag)
- `Sources/piqley/Plugins/PluginSetupScanner.swift` — Setup scan logic: prompt for config, validate secrets, run setup binaries
- `Sources/piqley/CLI/PluginCommand.swift` — `piqley plugin setup` command with optional plugin name and `--force` flag
- `Tests/piqleyTests/PluginConfigEntryTests.swift` — Tests for ConfigEntry decoding
- `Tests/piqleyTests/PluginConfigTests.swift` — Tests for PluginConfig sidecar load/save
- `Tests/piqleyTests/PluginSetupScannerTests.swift` — Tests for setup scan logic

### Modified Files
- `Sources/piqley/Plugins/PluginManifest.swift` — Remove `secrets`, add `config` and `setup` fields
- `Sources/piqley/Plugins/PluginDiscovery.swift` — Rename `plugin.json` → `manifest.json`
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift` — Rename `plugin.json` → `manifest.json`, read config from sidecar instead of `AppConfig.plugins`
- `Sources/piqley/Plugins/PluginRunner.swift` — Derive secrets from `config` entries with `secret_key`, add `PIQLEY_CONFIG_*` env vars
- `Sources/piqley/Config/Config.swift` — Remove `plugins` dictionary
- `Sources/piqley/CLI/SetupCommand.swift` — Run setup scan after bundled plugin install
- `Sources/piqley/Piqley.swift` — Register `PluginCommand`
- `Tests/piqleyTests/PluginManifestTests.swift` — Update for new manifest shape
- `Tests/piqleyTests/PluginDiscoveryTests.swift` — Rename `plugin.json` → `manifest.json`
- `Tests/piqleyTests/PipelineOrchestratorTests.swift` — Rename `plugin.json` → `manifest.json`, update config passing
- `Tests/piqleyTests/PluginRunnerTests.swift` — Update secret derivation, add config env var tests
- `Tests/piqleyTests/ConfigTests.swift` — Remove `plugins` dictionary tests

---

## Task 1: Rename `plugin.json` → `manifest.json`

A mechanical rename across the codebase. No logic changes.

**Files:**
- Modify: `Sources/piqley/Plugins/PluginDiscovery.swift:28`
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift:115`
- Modify: `Tests/piqleyTests/PluginDiscoveryTests.swift`
- Modify: `Tests/piqleyTests/PipelineOrchestratorTests.swift`
- Modify: `Tests/piqleyTests/PluginManifestTests.swift`
- Modify: `Tests/piqleyTests/PluginRunnerTests.swift`

- [ ] **Step 1: Update PluginDiscovery.swift**

Change `plugin.json` to `manifest.json` on line 28:

```swift
let manifestURL = url.appendingPathComponent("manifest.json")
```

- [ ] **Step 2: Update PipelineOrchestrator.swift**

Change `plugin.json` to `manifest.json` on line 115:

```swift
let manifestURL = pluginDir.appendingPathComponent("manifest.json")
```

- [ ] **Step 3: Update all test files**

Search for `"plugin.json"` in all test files and replace with `"manifest.json"`. Files:
- `PluginDiscoveryTests.swift`
- `PipelineOrchestratorTests.swift`
- `PluginManifestTests.swift` (if referencing file name)
- `PluginRunnerTests.swift` (if referencing file name)

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor: rename plugin.json to manifest.json"
```

---

## Task 2: Add `ConfigEntry` and `SetupConfig` models

The new manifest types that represent the unified config array.

**Files:**
- Create: `Sources/piqley/Plugins/PluginConfigEntry.swift`
- Create: `Tests/piqleyTests/PluginConfigEntryTests.swift`

- [ ] **Step 1: Write failing tests for ConfigEntry decoding**

```swift
// Tests/piqleyTests/PluginConfigEntryTests.swift
import Testing
import Foundation
@testable import piqley

@Suite("ConfigEntry")
struct PluginConfigEntryTests {

    // MARK: - Value entries

    @Test("decodes value entry with int default")
    func decodeValueEntryWithDefault() throws {
        let json = #"{"key": "quality", "type": "int", "value": 80}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(key, type, value) = entry else {
            Issue.record("Expected .value, got \(entry)"); return
        }
        #expect(key == "quality")
        #expect(type == .int)
        #expect(value == .number(80))
    }

    @Test("decodes value entry with null value")
    func decodeValueEntryWithNullValue() throws {
        let json = #"{"key": "url", "type": "string", "value": null}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(key, type, value) = entry else {
            Issue.record("Expected .value, got \(entry)"); return
        }
        #expect(key == "url")
        #expect(type == .string)
        #expect(value == .null)
    }

    @Test("decodes value entry with string default")
    func decodeValueEntryWithStringDefault() throws {
        let json = #"{"key": "format", "type": "string", "value": "jpeg"}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(_, _, value) = entry else {
            Issue.record("Expected .value"); return
        }
        #expect(value == .string("jpeg"))
    }

    @Test("decodes value entry with bool default")
    func decodeValueEntryWithBoolDefault() throws {
        let json = #"{"key": "verbose", "type": "bool", "value": true}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(_, type, value) = entry else {
            Issue.record("Expected .value"); return
        }
        #expect(type == .bool)
        #expect(value == .bool(true))
    }

    // MARK: - Secret entries

    @Test("decodes secret entry")
    func decodeSecretEntry() throws {
        let json = #"{"secret_key": "api-key", "type": "string"}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .secret(secretKey, type) = entry else {
            Issue.record("Expected .secret, got \(entry)"); return
        }
        #expect(secretKey == "api-key")
        #expect(type == .string)
    }

    @Test("rejects entry with both key and secret_key")
    func rejectDualEntry() throws {
        let json = #"{"key": "url", "secret_key": "api-key", "type": "string", "value": null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        }
    }

    // MARK: - Config array

    @Test("decodes mixed config array")
    func decodeConfigArray() throws {
        let json = #"""
        [
            {"key": "url", "type": "string", "value": null},
            {"key": "quality", "type": "int", "value": 80},
            {"secret_key": "api-key", "type": "string"}
        ]
        """#
        let entries = try JSONDecoder().decode([ConfigEntry].self, from: Data(json.utf8))
        #expect(entries.count == 3)
        if case .value = entries[0] {} else { Issue.record("Expected .value at index 0") }
        if case .value = entries[1] {} else { Issue.record("Expected .value at index 1") }
        if case .secret = entries[2] {} else { Issue.record("Expected .secret at index 2") }
    }

    // MARK: - SetupConfig

    @Test("decodes setup config with args")
    func decodeSetupConfig() throws {
        let json = #"{"command": "./setup.sh", "args": ["$PIQLEY_SECRET_API_KEY"]}"#
        let config = try JSONDecoder().decode(SetupConfig.self, from: Data(json.utf8))
        #expect(config.command == "./setup.sh")
        #expect(config.args == ["$PIQLEY_SECRET_API_KEY"])
    }

    @Test("decodes setup config without args defaults to empty")
    func decodeSetupConfigNoArgs() throws {
        let json = #"{"command": "./setup.sh"}"#
        let config = try JSONDecoder().decode(SetupConfig.self, from: Data(json.utf8))
        #expect(config.command == "./setup.sh")
        #expect(config.args == [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginConfigEntryTests 2>&1`
Expected: Compilation error — `ConfigEntry` and `SetupConfig` not defined

- [ ] **Step 3: Implement ConfigEntry and SetupConfig**

```swift
// Sources/piqley/Plugins/PluginConfigEntry.swift
import Foundation

/// The type of a config entry value.
enum ConfigValueType: String, Codable, Sendable {
    case string
    case int
    case float
    case bool
}

/// A single entry in a plugin's `config` array.
/// Either a regular value (`key`/`value`) or a secret (`secret_key`).
enum ConfigEntry: Codable, Sendable {
    case value(key: String, type: ConfigValueType, value: JSONValue)
    case secret(secretKey: String, type: ConfigValueType)

    private enum CodingKeys: String, CodingKey {
        case key, secretKey = "secret_key", type, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ConfigValueType.self, forKey: .type)
        let hasKey = container.contains(.key)
        let hasSecretKey = container.contains(.secretKey)

        if hasKey, hasSecretKey {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Config entry must have exactly one of 'key' or 'secret_key', not both"
                )
            )
        }

        if let secretKey = try container.decodeIfPresent(String.self, forKey: .secretKey) {
            self = .secret(secretKey: secretKey, type: type)
        } else if let key = try container.decodeIfPresent(String.self, forKey: .key) {
            let value = try container.decode(JSONValue.self, forKey: .value)
            self = .value(key: key, type: type, value: value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Config entry must have exactly one of 'key' or 'secret_key'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .value(key, type, value):
            try container.encode(key, forKey: .key)
            try container.encode(type, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .secret(secretKey, type):
            try container.encode(secretKey, forKey: .secretKey)
            try container.encode(type, forKey: .type)
        }
    }
}

/// Optional setup binary configuration in the plugin manifest.
struct SetupConfig: Codable, Sendable {
    let command: String
    let args: [String]

    init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case command, args
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginConfigEntryTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginConfigEntry.swift Tests/piqleyTests/PluginConfigEntryTests.swift
git commit -m "feat: add ConfigEntry and SetupConfig models"
```

---

## Task 3: Add `PluginConfig` sidecar model

The mutable `config.json` file per plugin.

**Files:**
- Create: `Sources/piqley/Plugins/PluginConfig.swift`
- Create: `Tests/piqleyTests/PluginConfigTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/piqleyTests/PluginConfigTests.swift
import Testing
import Foundation
@testable import piqley

@Suite("PluginConfig")
struct PluginConfigTests {

    @Test("empty config has no values and nil isSetUp")
    func emptyPluginConfig() {
        let config = PluginConfig()
        #expect(config.values.isEmpty)
        #expect(config.isSetUp == nil)
    }

    @Test("decodes config with values and isSetUp")
    func decodePluginConfig() throws {
        let json = #"{"values": {"url": "https://example.com", "quality": 80}, "isSetUp": true}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.values["url"] == .string("https://example.com"))
        #expect(config.values["quality"] == .number(80))
        #expect(config.isSetUp == true)
    }

    @Test("missing isSetUp decodes as nil")
    func decodePluginConfigMissingIsSetUp() throws {
        let json = #"{"values": {"url": "https://example.com"}}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        #expect(config.isSetUp == nil)
    }

    @Test("save and load round-trip")
    func saveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        var config = PluginConfig()
        config.values["quality"] = .number(80)
        config.isSetUp = true
        try config.save(to: url)

        let loaded = try PluginConfig.load(from: url)
        #expect(loaded.values["quality"] == .number(80))
        #expect(loaded.isSetUp == true)
    }

    @Test("loading from missing file returns empty config")
    func loadFromMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        let config = PluginConfig.load(fromIfExists: url)
        #expect(config.values.isEmpty)
        #expect(config.isSetUp == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginConfigTests 2>&1`
Expected: Compilation error — `PluginConfig` not defined

- [ ] **Step 3: Implement PluginConfig**

```swift
// Sources/piqley/Plugins/PluginConfig.swift
import Foundation

/// Per-plugin mutable configuration sidecar (`config.json`).
struct PluginConfig: Codable, Sendable {
    var values: [String: JSONValue] = [:]
    var isSetUp: Bool?

    init() {}

    static func load(from url: URL) throws -> PluginConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginConfig.self, from: data)
    }

    /// Loads from URL if the file exists, otherwise returns an empty config.
    static func load(fromIfExists url: URL) -> PluginConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return PluginConfig() }
        return (try? load(from: url)) ?? PluginConfig()
    }

    func save(to url: URL) throws {
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginConfigTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginConfig.swift Tests/piqleyTests/PluginConfigTests.swift
git commit -m "feat: add PluginConfig sidecar model"
```

---

## Task 4: Update `PluginManifest` — remove `secrets`, add `config` and `setup`

**Files:**
- Modify: `Sources/piqley/Plugins/PluginManifest.swift`
- Modify: `Tests/piqleyTests/PluginManifestTests.swift`

- [ ] **Step 1: Update PluginManifest tests**

Update existing tests to use the new manifest shape. Remove tests for `secrets` array. Add tests for `config` and `setup` fields. The manifest should decode `config` as `[ConfigEntry]` defaulting to `[]`, and `setup` as `SetupConfig?` defaulting to `nil`.

Key test cases:
- Manifest with config array containing value and secret entries
- Manifest with setup object
- Manifest with no config and no setup (backward compat — both default to empty/nil)
- Helper computed properties: `secretKeys` returns `[String]` of all `secret_key` entries, `valueEntries` returns just the value entries

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginManifestTests 2>&1`
Expected: Failures due to missing fields/properties

- [ ] **Step 3: Update PluginManifest**

In `PluginManifest.swift`:
- Remove `let secrets: [String]`
- Add `let config: [ConfigEntry]`
- Add `let setup: SetupConfig?`
- Update `CodingKeys` enum: remove `secrets`, add `config`, `setup`
- Update `init(from:)`: decode `config` with `decodeIfPresent` defaulting to `[]`, decode `setup` with `decodeIfPresent`
- Add computed property `secretKeys: [String]` that extracts `secret_key` values from config entries
- Add computed property `valueEntries: [(key: String, type: ConfigValueType, value: JSONValue)]` that extracts value entries

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginManifestTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginManifest.swift Tests/piqleyTests/PluginManifestTests.swift
git commit -m "feat: replace secrets array with unified config array in manifest"
```

---

## Task 5: Add plugin `data/` working directory

When a plugin is loaded, piqley creates a `data/` subdirectory inside the plugin's directory. All plugin processes (hooks and setup binaries) run with `data/` as their cwd.

**Files:**
- Modify: `Sources/piqley/Plugins/PluginDiscovery.swift`
- Modify: `Sources/piqley/Plugins/PluginRunner.swift`
- Modify: `Tests/piqleyTests/PluginDiscoveryTests.swift`

- [ ] **Step 1: Add test for data directory creation on load**

Add a test in `PluginDiscoveryTests` that verifies when a plugin is loaded, a `data/` directory exists inside the plugin directory afterward.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginDiscoveryTests 2>&1`
Expected: Failure — `data/` directory not created

- [ ] **Step 3: Create data directory in PluginDiscovery**

In `PluginDiscovery.loadManifests()`, after successfully decoding a manifest, create the `data/` directory:

```swift
let dataDir = url.appendingPathComponent("data")
try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
```

- [ ] **Step 4: Set cwd in PluginRunner**

In `PluginRunner.swift`, set `process.currentDirectoryURL` to the `data/` directory in both `runJSON` and `runPipe` methods:

```swift
process.currentDirectoryURL = plugin.directory.appendingPathComponent("data")
```

- [ ] **Step 5: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/Plugins/PluginDiscovery.swift Sources/piqley/Plugins/PluginRunner.swift Tests/piqleyTests/PluginDiscoveryTests.swift
git commit -m "feat: create data/ working directory for plugins, set as cwd"
```

---

## Task 6: Update `PluginRunner` — derive secrets from config, add `PIQLEY_CONFIG_*` env vars

**Files:**
- Modify: `Sources/piqley/Plugins/PluginRunner.swift`
- Modify: `Tests/piqleyTests/PluginRunnerTests.swift`

- [ ] **Step 1: Update PluginRunner tests**

Update tests that set up plugin manifests to use the new `config` array instead of `secrets`. Add a test verifying that `PIQLEY_CONFIG_*` environment variables are set from sidecar config values. The env var naming convention: `PIQLEY_CONFIG_` + key uppercased with `-` replaced by `_`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginRunnerTests 2>&1`
Expected: Failures

- [ ] **Step 3: Update PluginRunner**

In `PluginRunner.swift`:
- Add a `pluginConfig: PluginConfig` stored property alongside `plugin` and `secrets`
- Remove `pluginConfig: [String: JSONValue]` parameter from `run()` method signature — it now reads from `self.pluginConfig`
- In `buildEnvironment()`, add `PIQLEY_CONFIG_*` entries from `pluginConfig.values`:

```swift
for (key, value) in pluginConfig.values {
    let envKey = "PIQLEY_CONFIG_" + key.uppercased().replacingOccurrences(of: "-", with: "_")
    env[envKey] = displayValue(value)  // string as-is, number/bool via String()
}
```

- In `buildJSONPayload()`, pass `pluginConfig.values` instead of the old external parameter
- Update all call sites: `PluginRunner(plugin:, secrets:)` becomes `PluginRunner(plugin:, secrets:, pluginConfig:)` and `runner.run(hook:, tempFolder:, pluginConfig:, ...)` drops the `pluginConfig` parameter

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginRunnerTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginRunner.swift Tests/piqleyTests/PluginRunnerTests.swift
git commit -m "feat: derive secrets from config entries, add PIQLEY_CONFIG env vars"
```

---

## Task 7: Update `PipelineOrchestrator` — read config from sidecar

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift`
- Modify: `Tests/piqleyTests/PipelineOrchestratorTests.swift`

- [ ] **Step 1: Update PipelineOrchestrator tests**

Update test manifests to use `config` instead of `secrets`. Update test expectations: the orchestrator should load `config.json` from each plugin directory instead of reading from `AppConfig.plugins`. Remove any test setup that populates `AppConfig.plugins`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PipelineOrchestratorTests 2>&1`
Expected: Failures

- [ ] **Step 3: Update PipelineOrchestrator**

In `PipelineOrchestrator.swift`:
- In `run()`, replace `let pluginConfig = config.plugins[pluginName] ?? [:]` with loading the sidecar: `let pluginConfig = PluginConfig.load(fromIfExists: pluginDir.appendingPathComponent("config.json"))`
- Update `PluginRunner` construction to pass the loaded `PluginConfig`
- In `fetchSecrets()`, change `plugin.manifest.secrets` to `plugin.manifest.secretKeys`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PipelineOrchestratorTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift Tests/piqleyTests/PipelineOrchestratorTests.swift
git commit -m "feat: read plugin config from sidecar instead of central config"
```

---

## Task 8: Remove `plugins` dictionary from `AppConfig`

**Files:**
- Modify: `Sources/piqley/Config/Config.swift`
- Modify: `Tests/piqleyTests/ConfigTests.swift`

- [ ] **Step 1: Update ConfigTests**

Remove any tests that reference `AppConfig.plugins`. Update round-trip tests to not include `plugins`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1`
Expected: Failures or still passes (tests may just be removing references)

- [ ] **Step 3: Update AppConfig**

In `Config.swift`:
- Remove `var plugins: [String: [String: JSONValue]] = [:]`
- Remove `plugins` from `CodingKeys` enum
- Remove `plugins` decoding from `init(from:)`

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass (including any other tests that may have referenced `config.plugins`)

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Config/Config.swift Tests/piqleyTests/ConfigTests.swift
git commit -m "refactor: remove plugins dictionary from AppConfig"
```

---

## Task 9: Implement `PluginSetupScanner`

The core setup scan logic. This is the heart of the feature.

**Files:**
- Create: `Sources/piqley/Plugins/PluginSetupScanner.swift`
- Create: `Tests/piqleyTests/PluginSetupScannerTests.swift`

- [ ] **Step 1: Write failing tests for setup scanner**

Create test helpers (`MockInputSource`, `MockSecretStore`) and tests covering all three phases. The `InputSource` protocol must use `mutating func readLine()` so both the mock (which advances an index) and the real stdin (non-mutating) can conform — Swift allows non-mutating implementations to satisfy mutating protocol requirements.

```swift
// Tests/piqleyTests/PluginSetupScannerTests.swift
import Testing
import Foundation
@testable import piqley

/// Mock input source that returns canned responses in order.
struct MockInputSource: InputSource {
    var responses: [String]
    private var index = 0
    mutating func readLine() -> String? {
        guard index < responses.count else { return nil }
        defer { index += 1 }
        return responses[index]
    }
}

/// In-memory secret store for testing.
final class MockSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }
    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
}

@Suite("PluginSetupScanner")
struct PluginSetupScannerTests {

    private func makePlugin(
        name: String = "test-plugin",
        config: [ConfigEntry] = [],
        setup: SetupConfig? = nil
    ) throws -> LoadedPlugin {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = PluginManifest(name: name, pluginProtocolVersion: "1", config: config, setup: setup, hooks: [:])
        return LoadedPlugin(name: name, directory: dir, manifest: manifest)
    }

    @Test("prompts for null-default value and stores in sidecar")
    func promptRequiredValue() throws {
        let plugin = try makePlugin(config: [.value(key: "url", type: .string, value: .null)])
        let store = MockSecretStore()
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: ["https://example.com"]))
        try scanner.scan(plugin: plugin)

        let config = try PluginConfig.load(from: plugin.directory.appendingPathComponent("config.json"))
        #expect(config.values["url"] == .string("https://example.com"))
    }

    @Test("accepts default on empty input")
    func acceptDefault() throws {
        let plugin = try makePlugin(config: [.value(key: "quality", type: .int, value: .number(80))])
        let store = MockSecretStore()
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: [""]))
        try scanner.scan(plugin: plugin)

        let config = try PluginConfig.load(from: plugin.directory.appendingPathComponent("config.json"))
        #expect(config.values["quality"] == .number(80))
    }

    @Test("skips values already in sidecar")
    func skipExistingValues() throws {
        let plugin = try makePlugin(config: [.value(key: "url", type: .string, value: .null)])
        // Pre-populate sidecar
        var existing = PluginConfig()
        existing.values["url"] = .string("already-set")
        try existing.save(to: plugin.directory.appendingPathComponent("config.json"))

        let store = MockSecretStore()
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: []))
        try scanner.scan(plugin: plugin)

        let config = try PluginConfig.load(from: plugin.directory.appendingPathComponent("config.json"))
        #expect(config.values["url"] == .string("already-set"))
    }

    @Test("force flag clears existing values and re-prompts")
    func forceResetValues() throws {
        let plugin = try makePlugin(config: [.value(key: "url", type: .string, value: .null)])
        var existing = PluginConfig()
        existing.values["url"] = .string("old-value")
        try existing.save(to: plugin.directory.appendingPathComponent("config.json"))

        let store = MockSecretStore()
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: ["new-value"]))
        try scanner.scan(plugin: plugin, force: true)

        let config = try PluginConfig.load(from: plugin.directory.appendingPathComponent("config.json"))
        #expect(config.values["url"] == .string("new-value"))
    }

    @Test("re-prompts on invalid int input")
    func repromptInvalidInt() throws {
        let plugin = try makePlugin(config: [.value(key: "port", type: .int, value: .null)])
        let store = MockSecretStore()
        // First response is invalid, second is valid
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: ["abc", "8080"]))
        try scanner.scan(plugin: plugin)

        let config = try PluginConfig.load(from: plugin.directory.appendingPathComponent("config.json"))
        #expect(config.values["port"] == .number(8080))
    }

    @Test("prompts for missing secret and stores in keychain")
    func promptMissingSecret() throws {
        let plugin = try makePlugin(config: [.secret(secretKey: "api-key", type: .string)])
        let store = MockSecretStore()
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: ["my-secret"]))
        try scanner.scan(plugin: plugin)

        let stored = try store.getPluginSecret(plugin: "test-plugin", key: "api-key")
        #expect(stored == "my-secret")
    }

    @Test("skips secret already in keychain")
    func skipExistingSecret() throws {
        let plugin = try makePlugin(config: [.secret(secretKey: "api-key", type: .string)])
        let store = MockSecretStore()
        try store.setPluginSecret(plugin: "test-plugin", key: "api-key", value: "existing")
        // No input responses needed — should not prompt
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: []))
        try scanner.scan(plugin: plugin)

        let stored = try store.getPluginSecret(plugin: "test-plugin", key: "api-key")
        #expect(stored == "existing")
    }

    @Test("setup binary not found leaves isSetUp unset")
    func setupBinaryNotFound() throws {
        let plugin = try makePlugin(setup: SetupConfig(command: "./nonexistent.sh"))
        let store = MockSecretStore()
        var scanner = PluginSetupScanner(secretStore: store, inputSource: MockInputSource(responses: []))
        try scanner.scan(plugin: plugin)

        let config = try PluginConfig.load(from: plugin.directory.appendingPathComponent("config.json"))
        #expect(config.isSetUp != true)
    }
}
```

Note: `PluginManifest` will need a memberwise initializer (or test-only init) for constructing manifests in tests. Add this alongside Task 4's manifest changes.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginSetupScannerTests 2>&1`
Expected: Compilation error

- [ ] **Step 3: Implement PluginSetupScanner — config value resolution**

```swift
// Sources/piqley/Plugins/PluginSetupScanner.swift
import Foundation
import Logging

protocol InputSource {
    mutating func readLine() -> String?
}

struct StdinInputSource: InputSource {
    func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }
}

struct PluginSetupScanner {
    let secretStore: any SecretStore
    var inputSource: any InputSource
    private let logger = Logger(label: "piqley.setup-scanner")

    /// Runs setup scan for a single plugin.
    /// - Parameters:
    ///   - plugin: The loaded plugin to scan
    ///   - force: If true, clears existing config values and isSetUp before scanning
    mutating func scan(plugin: LoadedPlugin, force: Bool = false) throws {
        let configURL = plugin.directory.appendingPathComponent("config.json")
        var pluginConfig = force ? PluginConfig() : PluginConfig.load(fromIfExists: configURL)

        // Phase 1: Config value resolution
        for entry in plugin.manifest.config {
            guard case let .value(key, type, defaultValue) = entry else { continue }
            if !force, pluginConfig.values[key] != nil { continue }
            let resolved = promptForValue(pluginName: plugin.name, key: key, type: type, defaultValue: defaultValue)
            pluginConfig.values[key] = resolved
        }

        // Phase 2: Secret validation
        let hasSecrets = plugin.manifest.config.contains { if case .secret = $0 { return true } else { return false } }
        for entry in plugin.manifest.config {
            guard case let .secret(secretKey, _) = entry else { continue }
            do {
                _ = try secretStore.getPluginSecret(plugin: plugin.name, key: secretKey)
            } catch {
                let value = promptForSecret(pluginName: plugin.name, key: secretKey)
                try secretStore.setPluginSecret(plugin: plugin.name, key: secretKey, value: value)
            }
        }
        // Store pluginProtocolVersion once after all secrets are validated
        if hasSecrets {
            try secretStore.setPluginSecret(
                plugin: plugin.name,
                key: "pluginProtocolVersion",
                value: plugin.manifest.pluginProtocolVersion
            )
        }

        // Phase 3: Setup binary
        if let setup = plugin.manifest.setup, pluginConfig.isSetUp != true {
            let executable = resolveExecutable(setup.command, pluginDir: plugin.directory)
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                logger.error("[\(plugin.name)] Setup command not found or not executable: \(executable)")
                try pluginConfig.save(to: configURL)
                return
            }

            let secrets = fetchSecrets(for: plugin)
            let environment = buildSetupEnvironment(pluginConfig: pluginConfig, secrets: secrets)
            let args = substitute(args: setup.args, environment: environment)

            let exitCode = try runSetupBinary(executable: executable, args: args, environment: environment, pluginDir: plugin.directory)
            if exitCode == 0 {
                pluginConfig.isSetUp = true
            } else {
                logger.error("[\(plugin.name)] Setup binary exited with code \(exitCode)")
            }
        }

        try pluginConfig.save(to: configURL)
    }

    // MARK: - Prompting

    private mutating func promptForValue(
        pluginName: String, key: String, type: ConfigValueType, defaultValue: JSONValue
    ) -> JSONValue {
        let hasDefault = defaultValue != .null && defaultValue != .string("")
        while true {
            if hasDefault {
                let defaultStr = displayValue(defaultValue)
                print("[\(pluginName)] \(key) [\(defaultStr)]: ", terminator: "")
            } else {
                print("[\(pluginName)] \(key): ", terminator: "")
            }
            let input = inputSource.readLine() ?? ""
            if input.isEmpty, hasDefault {
                return defaultValue
            }
            if input.isEmpty {
                print("Value is required.")
                continue
            }
            if let parsed = parseInput(input, as: type) {
                return parsed
            }
            print("Invalid \(type.rawValue) value. Try again.")
        }
    }

    private mutating func promptForSecret(pluginName: String, key: String) -> String {
        while true {
            print("[\(pluginName)] \(key) (secret): ", terminator: "")
            let input = inputSource.readLine() ?? ""
            if !input.isEmpty { return input }
            print("Value is required.")
        }
    }

    // MARK: - Parsing

    private func parseInput(_ input: String, as type: ConfigValueType) -> JSONValue? {
        switch type {
        case .string:
            return .string(input)
        case .int:
            guard let intVal = Int(input) else { return nil }
            return .number(Double(intVal))
        case .float:
            guard let floatVal = Double(input) else { return nil }
            return .number(floatVal)
        case .bool:
            switch input.lowercased() {
            case "true", "yes", "y", "1": return .bool(true)
            case "false", "no", "n", "0": return .bool(false)
            default: return nil
            }
        }
    }

    private func displayValue(_ value: JSONValue) -> String {
        switch value {
        case let .string(s): return s
        case let .number(n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case let .bool(b): return String(b)
        default: return ""
        }
    }

    // MARK: - Setup binary helpers

    private func resolveExecutable(_ command: String, pluginDir: URL) -> String {
        if command.hasPrefix("/") { return command }
        return pluginDir.appendingPathComponent(command).path
    }

    private func fetchSecrets(for plugin: LoadedPlugin) -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secretKeys {
            if let value = try? secretStore.getPluginSecret(plugin: plugin.name, key: key) {
                result[key] = value
            }
        }
        return result
    }

    private func buildSetupEnvironment(pluginConfig: PluginConfig, secrets: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in pluginConfig.values {
            let envKey = "PIQLEY_CONFIG_" + key.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envKey] = displayValue(value)
        }
        for (key, value) in secrets {
            let envKey = "PIQLEY_SECRET_" + key.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envKey] = value
        }
        return env
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

    private func runSetupBinary(executable: String, args: [String], environment: [String: String], pluginDir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Merge custom env vars with system environment so PATH etc. are available
        var mergedEnv = ProcessInfo.processInfo.environment
        mergedEnv.merge(environment) { _, new in new }
        process.environment = mergedEnv
        process.currentDirectoryURL = pluginDir.appendingPathComponent("data")
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginSetupScannerTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Plugins/PluginSetupScanner.swift Tests/piqleyTests/PluginSetupScannerTests.swift
git commit -m "feat: implement PluginSetupScanner with config, secret, and setup binary support"
```

---

## Task 10: Add `piqley plugin setup` command

**Files:**
- Create: `Sources/piqley/CLI/PluginCommand.swift`
- Modify: `Sources/piqley/Piqley.swift`

- [ ] **Step 1: Create PluginCommand**

```swift
// Sources/piqley/CLI/PluginCommand.swift
import ArgumentParser
import Foundation
import Logging

struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins",
        subcommands: [SetupSubcommand.self]
    )

    struct SetupSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Run interactive setup for plugins"
        )

        @Argument(help: "Plugin name (runs all plugins if omitted)")
        var pluginName: String?

        @Flag(help: "Force re-setup (clears existing config values and isSetUp)")
        var force = false

        private var logger: Logger { Logger(label: "piqley.plugin.setup") }

        func run() throws {
            let config: AppConfig
            do {
                config = try AppConfig.load()
            } catch {
                throw ValidationError("Failed to load config: \(formatError(error))\nRun 'piqley setup' first.")
            }

            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests(disabled: config.disabledPlugins)

            let secretStore = KeychainSecretStore()
            var scanner = PluginSetupScanner(
                secretStore: secretStore,
                inputSource: StdinInputSource()
            )

            let targetPlugins: [LoadedPlugin]
            if let name = pluginName {
                guard let plugin = plugins.first(where: { $0.name == name }) else {
                    throw ValidationError("Plugin '\(name)' not found")
                }
                targetPlugins = [plugin]
            } else {
                targetPlugins = plugins
            }

            for plugin in targetPlugins {
                try scanner.scan(plugin: plugin, force: force)
            }

            print("\nPlugin setup complete.")
        }
    }
}
```

- [ ] **Step 2: Register PluginCommand in Piqley.swift**

Add `PluginCommand.self` to the subcommands array in `Piqley.swift`.

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/CLI/PluginCommand.swift Sources/piqley/Piqley.swift
git commit -m "feat: add piqley plugin setup command"
```

---

## Task 11: Update `SetupCommand` to run setup scan after install

**Files:**
- Modify: `Sources/piqley/CLI/SetupCommand.swift`

- [ ] **Step 1: Update SetupCommand**

After `installBundledPlugins()`, add a call to discover plugins and run `PluginSetupScanner.scan()` on each:

```swift
// After installBundledPlugins()
let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
let plugins = try discovery.loadManifests(disabled: config.disabledPlugins)

if !plugins.isEmpty {
    print("\nConfiguring plugins...\n")
    let secretStore = KeychainSecretStore()
    var scanner = PluginSetupScanner(
        secretStore: secretStore,
        inputSource: StdinInputSource()
    )
    for plugin in plugins {
        try scanner.scan(plugin: plugin)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/CLI/SetupCommand.swift
git commit -m "feat: run plugin setup scan after bundled plugin install"
```

---

## Task 12: Run full test suite and fix any remaining issues

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass

- [ ] **Step 2: Fix any failures**

Address compilation errors or test failures from the integration of all changes.

- [ ] **Step 3: Final commit (if needed)**

```bash
git add -A && git commit -m "fix: resolve test failures from plugin setup integration"
```
