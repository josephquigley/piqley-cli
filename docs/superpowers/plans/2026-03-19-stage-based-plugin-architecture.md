# Stage-Based Plugin Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the plugin system so plugins vend per-stage JSON config files with pre/post binary rulesets, the manifest handles only identity/secrets/dependencies, and the CLI discovers stages from `stage-*.json` files.

**Architecture:** Three-repo bottom-up approach — PiqleyCore first (new `StageConfig` type, remove `hooks` from manifest, remove `rules` from config, remove `hook` from `MatchConfig`), then PiqleyPluginSDK (new `StageBuilder`, update manifest/config builders), then piqley-cli (stage discovery, orchestrator rework with pre/post rules and MetadataBuffer invalidation, update plugin init).

**Tech Stack:** Swift 6, Swift Testing, PiqleyCore, PiqleyPluginSDK, piqley-cli

**Spec:** `docs/superpowers/specs/2026-03-19-stage-based-plugin-architecture-design.md`

---

## File Structure

### piqley-core (modified files)

| File | Responsibility |
|------|---------------|
| `Sources/PiqleyCore/Config/Rule.swift` | Remove `hook` from `MatchConfig` |
| `Sources/PiqleyCore/Config/PluginConfig.swift` | Remove `rules` field |
| `Sources/PiqleyCore/Config/StageConfig.swift` | **New:** `StageConfig` struct with `preRules`, `binary`, `postRules` |
| `Sources/PiqleyCore/Manifest/PluginManifest.swift` | Remove `hooks` field, remove `unknownHooks()` |
| `Sources/PiqleyCore/Validation/ManifestValidator.swift` | Remove hooks-related validation |
| `Sources/PiqleyCore/Constants/PluginFile.swift` | Add `stagePrefix` constant |
| `Tests/PiqleyCoreTests/ConfigCodingTests.swift` | Update tests for removed fields, add `StageConfig` tests |
| `Tests/PiqleyCoreTests/ManifestCodingTests.swift` | Update tests for hookless manifest |
| `Tests/PiqleyCoreTests/ManifestValidatorTests.swift` | Update validation tests |

### piqley-plugin-sdk (modified files)

| File | Responsibility |
|------|---------------|
| `swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift` | Remove `Rules` block, remove `ConfigRule`, keep `Values` |
| `swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift` | Remove `Hooks`/`HookEntry` blocks |
| `swift/PiqleyPluginSDK/Builders/StageBuilder.swift` | **New:** `buildStage` DSL with `PreRules`, `Binary`, `PostRules` |
| `swift/PiqleyPluginSDK/Builders/MatchField.swift` | No changes needed |
| `swift/Tests/ConfigBuilderTests.swift` | Update for removed rules |
| `swift/Tests/ManifestBuilderTests.swift` | Update for removed hooks |
| `swift/Tests/StageBuilderTests.swift` | **New:** Tests for `buildStage` |

### piqley-cli (modified files)

| File | Responsibility |
|------|---------------|
| `Sources/piqley/Plugins/PluginDiscovery.swift` | Add stage file scanning, update `LoadedPlugin`, update `autoAppend` |
| `Sources/piqley/Plugins/PluginConfig.swift` | Remove `rules:` from helper methods, delete `withRules` |
| `Sources/piqley/State/RuleEvaluator.swift` | Remove hook filtering from `CompiledRule` and `evaluate` |
| `Sources/piqley/State/MetadataBuffer.swift` | Add `invalidateAll()` method |
| `Sources/piqley/Pipeline/PipelineOrchestrator.swift` | Rework to use stages with pre/post rules and buffer invalidation |
| `Sources/piqley/CLI/PluginCommand.swift` | Update `InitSubcommand` for stage-based init |
| `Tests/piqleyTests/PluginDiscoveryTests.swift` | Update for stage-based discovery |
| `Tests/piqleyTests/RuleEvaluatorTests.swift` | Remove hook filtering assertions |

---

### Task 1: Add `StageConfig` to PiqleyCore

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/StageConfig.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ConfigCodingTests.swift`

- [ ] **Step 1: Write failing tests for StageConfig**

Add to the end of `ConfigCodingTests.swift`:

```swift
// MARK: - StageConfig

@Test func decodeFullStageConfig() throws {
    let json = """
    {
        "preRules": [
            {
                "match": {"field": "original:TIFF:Model", "pattern": "glob:Canon*"},
                "emit": [{"field": "keywords", "values": ["canon"]}]
            }
        ],
        "binary": {
            "command": "./bin/my-plugin",
            "args": ["--quality", "high"],
            "timeout": 60,
            "protocol": "json"
        },
        "postRules": [
            {
                "match": {"field": "my-plugin:status", "pattern": "done"},
                "emit": [{"field": "keywords", "values": ["processed"]}],
                "write": [{"action": "add", "field": "IPTC:Keywords", "values": ["processed"]}]
            }
        ]
    }
    """
    let stage = try JSONDecoder().decode(StageConfig.self, from: Data(json.utf8))
    #expect(stage.preRules?.count == 1)
    #expect(stage.preRules?[0].match.field == "original:TIFF:Model")
    #expect(stage.binary?.command == "./bin/my-plugin")
    #expect(stage.binary?.timeout == 60)
    #expect(stage.postRules?.count == 1)
    #expect(stage.postRules?[0].write.count == 1)
}

@Test func decodeBinaryOnlyStageConfig() throws {
    let json = """
    {
        "binary": {"command": "./bin/tool", "timeout": 30}
    }
    """
    let stage = try JSONDecoder().decode(StageConfig.self, from: Data(json.utf8))
    #expect(stage.preRules == nil)
    #expect(stage.binary?.command == "./bin/tool")
    #expect(stage.postRules == nil)
}

@Test func decodeRulesOnlyStageConfig() throws {
    let json = """
    {
        "preRules": [
            {
                "match": {"field": "title", "pattern": ".*"},
                "emit": [{"field": "keywords", "values": ["tagged"]}]
            }
        ]
    }
    """
    let stage = try JSONDecoder().decode(StageConfig.self, from: Data(json.utf8))
    #expect(stage.preRules?.count == 1)
    #expect(stage.binary == nil)
    #expect(stage.postRules == nil)
}

@Test func decodeEmptyStageConfig() throws {
    let json = "{}"
    let stage = try JSONDecoder().decode(StageConfig.self, from: Data(json.utf8))
    #expect(stage.preRules == nil)
    #expect(stage.binary == nil)
    #expect(stage.postRules == nil)
}

@Test func encodeRoundTripStageConfig() throws {
    let stage = StageConfig(
        preRules: [Rule(
            match: MatchConfig(field: "title", pattern: "test"),
            emit: [EmitConfig(field: "keywords", values: ["a"])]
        )],
        binary: HookConfig(command: "./bin/tool", timeout: 30),
        postRules: nil
    )
    let data = try JSONEncoder().encode(stage)
    let decoded = try JSONDecoder().decode(StageConfig.self, from: data)
    #expect(decoded.preRules?.count == 1)
    #expect(decoded.binary?.command == "./bin/tool")
    #expect(decoded.postRules == nil)
}

@Test func stageConfigIsEmpty() {
    let empty = StageConfig(preRules: nil, binary: nil, postRules: nil)
    #expect(empty.isEmpty)

    let notEmpty = StageConfig(
        preRules: [Rule(match: MatchConfig(field: "x", pattern: "y"), emit: [])],
        binary: nil,
        postRules: nil
    )
    #expect(!notEmpty.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

Expected: compilation error (StageConfig doesn't exist)

- [ ] **Step 3: Create StageConfig**

Create `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/StageConfig.swift`:

```swift
/// Per-stage configuration for a piqley plugin.
/// Each stage file (`stage-<name>.json`) contains up to three optional sections.
public struct StageConfig: Codable, Sendable, Equatable {
    /// Rules evaluated before the binary runs.
    public let preRules: [Rule]?
    /// Binary execution configuration.
    public let binary: HookConfig?
    /// Rules evaluated after the binary runs.
    public let postRules: [Rule]?

    public init(preRules: [Rule]? = nil, binary: HookConfig? = nil, postRules: [Rule]? = nil) {
        self.preRules = preRules
        self.binary = binary
        self.postRules = postRules
    }

    /// Whether all three sections are nil (empty stage file).
    public var isEmpty: Bool {
        preRules == nil && binary == nil && postRules == nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Config/StageConfig.swift Tests/PiqleyCoreTests/ConfigCodingTests.swift
git commit -m "feat: add StageConfig type for per-stage plugin configuration"
```

---

### Task 2: Remove `hook` from `MatchConfig` in PiqleyCore

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/Rule.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ConfigCodingTests.swift`

- [ ] **Step 1: Update tests — remove hook assertions, add hookless test**

In `ConfigCodingTests.swift`, update these tests:

`decodeRule` — change the JSON to remove `"hook": "pre-process"` and remove the `#expect(rule.match.hook == "pre-process")` line:

```swift
@Test func decodeRule() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": "^Draft"},
        "emit": [{"field": "status", "values": ["draft", "wip"]}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.match.field == "title")
    #expect(rule.match.pattern == "^Draft")
    #expect(rule.emit[0].field == "status")
    #expect(rule.emit[0].values == ["draft", "wip"])
}
```

`decodeMinimalRule` — remove the `#expect(rule.match.hook == nil)` line.

`encodeRoundTripRule` — change the `MatchConfig` init to remove `hook:`:

```swift
@Test func encodeRoundTripRule() throws {
    let rule = Rule(
        match: MatchConfig(field: "category", pattern: "tech"),
        emit: [EmitConfig(field: "tag", values: ["technology"])]
    )
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(Rule.self, from: data)
    #expect(decoded.match.field == rule.match.field)
    #expect(decoded.match.pattern == rule.match.pattern)
    #expect(decoded.emit[0].field == rule.emit[0].field)
    #expect(decoded.emit[0].values == rule.emit[0].values)
}
```

`encodeRoundTripPluginConfig` — remove `hook:` from the `MatchConfig` init.

Also add a test that verifies `hook` in JSON is silently ignored (backward compat during transition):

```swift
@Test func decodeMatchConfigIgnoresHookField() throws {
    let json = """
    {
        "match": {"hook": "pre-process", "field": "title", "pattern": "test"},
        "emit": [{"field": "keywords", "values": ["a"]}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.match.field == "title")
    #expect(rule.match.pattern == "test")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

Expected: compilation errors due to `hook` parameter removal

- [ ] **Step 3: Update MatchConfig**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/Rule.swift`, replace `MatchConfig`:

```swift
/// Match configuration for a declarative metadata rule.
public struct MatchConfig: Codable, Sendable, Equatable {
    /// The metadata field to match against.
    public let field: String
    /// The regex pattern to match against the field value.
    public let pattern: String

    public init(field: String, pattern: String) {
        self.field = field
        self.pattern = pattern
    }
}
```

Note: By removing `hook` from the struct and not listing it in `CodingKeys`, the decoder will silently ignore any `"hook"` key in JSON — which is the desired backward-compat behavior.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Config/Rule.swift Tests/PiqleyCoreTests/ConfigCodingTests.swift
git commit -m "feat: remove hook from MatchConfig — stage files imply the hook"
```

---

### Task 3: Remove `hooks` from `PluginManifest` and update validator

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Validation/ManifestValidator.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ManifestCodingTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ManifestValidatorTests.swift`

- [ ] **Step 1: Update ManifestCodingTests**

Remove all `hooks` references. Update tests:

`decodeFullManifest` — remove `"hooks"` from JSON, remove the `#expect(manifest.hooks["pre-process"] != nil)` line:

```swift
@Test func decodeFullManifest() throws {
    let json = """
    {
        "name": "MyPlugin",
        "pluginProtocolVersion": "1.0",
        "pluginVersion": "2.3.1",
        "config": [
            {"key": "apiUrl", "type": "string", "value": "https://example.com"},
            {"secret_key": "API_TOKEN", "type": "string"}
        ],
        "setup": {"command": "setup.sh"},
        "dependencies": ["other-plugin"]
    }
    """
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    #expect(manifest.name == "MyPlugin")
    #expect(manifest.pluginProtocolVersion == "1.0")
    #expect(manifest.pluginVersion == SemanticVersion(major: 2, minor: 3, patch: 1))
    #expect(manifest.config.count == 2)
    #expect(manifest.setup?.command == "setup.sh")
    #expect(manifest.dependencies?.count == 1)
    #expect(manifest.dependencyNames == ["other-plugin"])
}
```

`decodeMinimalManifest` — remove hooks:

```swift
@Test func decodeMinimalManifest() throws {
    let json = """
    {
        "name": "MinimalPlugin",
        "pluginProtocolVersion": "1.0"
    }
    """
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    #expect(manifest.name == "MinimalPlugin")
    #expect(manifest.pluginProtocolVersion == "1.0")
    #expect(manifest.pluginVersion == nil)
    #expect(manifest.config.isEmpty)
    #expect(manifest.setup == nil)
    #expect(manifest.dependencies == nil)
}
```

`secretKeys` and `valueEntries` — remove `"hooks": {}` from JSON.

Remove the `unknownHooks` test entirely.

`manifestEncodeRoundTrip` — remove `hooks:` from init:

```swift
@Test func manifestEncodeRoundTrip() throws {
    let original = PluginManifest(
        name: "TestPlugin",
        pluginProtocolVersion: "1.0",
        pluginVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
        config: [.value(key: "url", type: .string, value: .string("http://example.com"))]
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
    #expect(decoded.name == original.name)
    #expect(decoded.pluginProtocolVersion == original.pluginProtocolVersion)
    #expect(decoded.pluginVersion == original.pluginVersion)
    #expect(decoded.config.count == original.config.count)
}
```

Add a test that JSON with `hooks` decodes without error (silently ignored):

```swift
@Test func decodeManifestIgnoresLegacyHooks() throws {
    let json = """
    {
        "name": "LegacyPlugin",
        "pluginProtocolVersion": "1.0",
        "hooks": {"pre-process": {"command": "run"}}
    }
    """
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    #expect(manifest.name == "LegacyPlugin")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ManifestCodingTests 2>&1 | tail -20`

Expected: compilation errors

- [ ] **Step 3: Update PluginManifest**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`, remove:
- The `hooks` property (line 9)
- The `hooks` parameter from `init` (line 18)
- The `hooks` assignment in init (line 26)
- The `hooks` `CodingKey` (line 36)
- The `hooks` decoding line (line 53)
- The `unknownHooks()` method (lines 82-85)

Updated file:

```swift
/// The manifest for a piqley plugin, describing its metadata, configuration, and dependencies.
public struct PluginManifest: Codable, Sendable, Equatable {
    public let name: String
    public let pluginProtocolVersion: String
    public let pluginVersion: SemanticVersion?
    public let config: [ConfigEntry]
    public let setup: SetupConfig?
    public let dependencies: [PluginDependency]?

    public init(
        name: String,
        pluginProtocolVersion: String,
        pluginVersion: SemanticVersion? = nil,
        config: [ConfigEntry] = [],
        setup: SetupConfig? = nil,
        dependencies: [PluginDependency]? = nil
    ) {
        self.name = name
        self.pluginProtocolVersion = pluginProtocolVersion
        self.pluginVersion = pluginVersion
        self.config = config
        self.setup = setup
        self.dependencies = dependencies
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case pluginProtocolVersion
        case pluginVersion
        case config
        case setup
        case dependencies
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        pluginProtocolVersion = try container.decode(String.self, forKey: .pluginProtocolVersion)
        pluginVersion = try container.decodeIfPresent(SemanticVersion.self, forKey: .pluginVersion)
        config = try container.decodeIfPresent([ConfigEntry].self, forKey: .config) ?? []
        setup = try container.decodeIfPresent(SetupConfig.self, forKey: .setup)
        if let structured = try? container.decodeIfPresent([PluginDependency].self, forKey: .dependencies) {
            dependencies = structured
        } else if let names = try? container.decodeIfPresent([String].self, forKey: .dependencies) {
            dependencies = names.map { PluginDependency(name: $0) }
        } else {
            dependencies = nil
        }
    }

    /// The dependency identifiers as plain strings (for backward-compatible pipeline resolution).
    public var dependencyNames: [String] {
        dependencies?.map(\.identifier) ?? []
    }

    /// The secret environment variable keys declared in config.
    public var secretKeys: [String] {
        config.compactMap { entry in
            if case .secret(let key, _) = entry { return key }
            return nil
        }
    }

    /// The value entries declared in config (key, type, value tuples).
    public var valueEntries: [(key: String, type: ConfigValueType, value: JSONValue)] {
        config.compactMap { entry in
            if case .value(let key, let type_, let value) = entry {
                return (key: key, type: type_, value: value)
            }
            return nil
        }
    }
}
```

- [ ] **Step 4: Update ManifestValidator**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Validation/ManifestValidator.swift`, remove hooks-related validation:

```swift
/// Validates a PluginManifest for constraint violations and potential issues.
public enum ManifestValidator {

    /// Returns a list of error messages for constraint violations in the manifest.
    /// An empty array means the manifest is valid.
    public static func validate(_ manifest: PluginManifest) -> [String] {
        var errors: [String] = []

        if manifest.name.isEmpty {
            errors.append("Plugin name must not be empty.")
        }

        if manifest.pluginProtocolVersion.isEmpty {
            errors.append("Plugin protocol version must not be empty.")
        }

        return errors
    }
}
```

- [ ] **Step 5: Update ManifestValidatorTests**

In `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ManifestValidatorTests.swift`, remove any tests that reference hooks. Update manifests in remaining tests to not include hooks. (Read the test file first to see exactly what needs changing.)

- [ ] **Step 6: Run all PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 7: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Manifest/PluginManifest.swift Sources/PiqleyCore/Validation/ManifestValidator.swift Tests/PiqleyCoreTests/ManifestCodingTests.swift Tests/PiqleyCoreTests/ManifestValidatorTests.swift
git commit -m "feat: remove hooks from PluginManifest — stages replace hooks"
```

---

### Task 4: Remove `rules` from `PluginConfig`, add stage prefix constant, update CLI helpers

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/PluginConfig.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Constants/PluginFile.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ConfigCodingTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginConfig.swift`

- [ ] **Step 1: Update PluginConfig tests**

In `ConfigCodingTests.swift`, update:

`decodePluginConfigWithRules` — rename to `decodePluginConfigIgnoresLegacyRules` and verify rules key is silently ignored:

```swift
@Test func decodePluginConfigIgnoresLegacyRules() throws {
    let json = """
    {
        "values": {"apiUrl": "https://example.com"},
        "isSetUp": true,
        "rules": [
            {
                "match": {"field": "title", "pattern": ".*"},
                "emit": [{"field": "keywords", "values": ["any"]}]
            }
        ]
    }
    """
    let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
    #expect(config.values["apiUrl"] == .string("https://example.com"))
    #expect(config.isSetUp == true)
}
```

`decodeEmptyPluginConfig` — remove `#expect(config.rules.isEmpty)`.

`decodePluginConfigWithoutRules` — remove `#expect(config.rules.isEmpty)`.

`encodeRoundTripPluginConfig` — remove `rules:` from init, remove rules assertions:

```swift
@Test func encodeRoundTripPluginConfig() throws {
    let original = PluginConfig(
        values: ["url": .string("http://example.com")],
        isSetUp: false
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PluginConfig.self, from: data)
    #expect(decoded.values["url"] == .string("http://example.com"))
    #expect(decoded.isSetUp == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

Expected: compilation errors

- [ ] **Step 3: Update PluginConfig**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/PluginConfig.swift`:

```swift
/// Runtime configuration for a piqley plugin instance.
public struct PluginConfig: Codable, Sendable, Equatable {
    /// The key-value configuration values for this plugin instance.
    public let values: [String: JSONValue]
    /// Whether the plugin has been set up. Nil if unknown.
    public let isSetUp: Bool?

    public init(values: [String: JSONValue] = [:], isSetUp: Bool? = nil) {
        self.values = values
        self.isSetUp = isSetUp
    }

    private enum CodingKeys: String, CodingKey {
        case values
        case isSetUp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
        isSetUp = try container.decodeIfPresent(Bool.self, forKey: .isSetUp)
    }
}
```

- [ ] **Step 4: Add stage prefix constant**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Constants/PluginFile.swift`:

```swift
/// Standard filenames within a plugin directory.
public enum PluginFile {
    public static let manifest = "manifest.json"
    public static let config = "config.json"
    public static let executionLog = "logs/execution.jsonl"
    /// Prefix for stage configuration files (e.g. "stage-pre-process.json").
    public static let stagePrefix = "stage-"
    /// Suffix for stage configuration files.
    public static let stageSuffix = ".json"
}
```

- [ ] **Step 5: Run all PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Update CLI PluginConfig extension**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginConfig.swift`, remove `rules:` from all `PluginConfig()` inits and delete `withRules`:

```swift
import Foundation
import PiqleyCore

extension PluginConfig {
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

    /// Returns a new PluginConfig with the given values dictionary.
    func withValues(_ values: [String: JSONValue]) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp)
    }

    /// Returns a new PluginConfig with a single value updated.
    func settingValue(_ value: JSONValue, forKey key: String) -> PluginConfig {
        var newValues = values
        newValues[key] = value
        return PluginConfig(values: newValues, isSetUp: isSetUp)
    }

    /// Returns a new PluginConfig with isSetUp set to the given value.
    func withIsSetUp(_ isSetUp: Bool?) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp)
    }
}
```

- [ ] **Step 7: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Config/PluginConfig.swift Sources/PiqleyCore/Constants/PluginFile.swift Tests/PiqleyCoreTests/ConfigCodingTests.swift
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Plugins/PluginConfig.swift
cd /Users/wash/Developer/tools/piqley/piqley-core && git commit -m "feat: remove rules from PluginConfig, add stage file constants"
cd /Users/wash/Developer/tools/piqley/piqley-cli && git commit -m "fix: update PluginConfig helpers for rules removal"
```

---

### Task 5: Update ManifestBuilder in PiqleyPluginSDK

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/ManifestBuilderTests.swift`

- [ ] **Step 1: Update ManifestBuilderTests**

Remove all `Hooks {}` blocks from test manifests. Remove the hooks-related tests. Update tests:

```swift
@Test func buildMinimalManifest() throws {
    let manifest = try buildManifest {
        Name("my-plugin")
        ProtocolVersion("1.0")
    }
    #expect(manifest.name == "my-plugin")
    #expect(manifest.pluginProtocolVersion == "1.0")
    #expect(manifest.config.isEmpty)
    #expect(manifest.setup == nil)
    #expect(manifest.dependencies == nil)
}

@Test func buildFullManifest() throws {
    let manifest = try buildManifest {
        Name("full-plugin")
        ProtocolVersion("2.0")
        try PluginVersion("1.2.3")
        ConfigEntries {
            Value("quality", type: .int, default: .number(80))
            Secret("API_KEY", type: .string)
        }
        Setup(command: "setup.sh", args: ["--verbose"])
        Dependencies {
            "original"
            "hashtag"
        }
    }

    #expect(manifest.name == "full-plugin")
    #expect(manifest.pluginProtocolVersion == "2.0")
    #expect(manifest.pluginVersion == SemanticVersion(major: 1, minor: 2, patch: 3))
    #expect(manifest.config.count == 2)
    #expect(manifest.setup?.command == "setup.sh")
    #expect(manifest.setup?.args == ["--verbose"])
    #expect(manifest.dependencyNames == ["original", "hashtag"])
}
```

Remove `buildRulesOnlyHook` test.

Update `buildStringDependency`, `buildStateKeyTypeDependency`, `buildMixedDependencies` — remove `Hooks {}` blocks.

Remove `writeValidationCatchesBadManifest` test (it validates hooks + batchProxy).

Update `writeSuccessRoundTrip` — remove hooks:

```swift
@Test func writeSuccessRoundTrip() throws {
    let manifest = try buildManifest {
        Name("write-plugin")
        ProtocolVersion("1.0")
    }

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try manifest.writeValidated(to: tempDir)

    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    #expect(FileManager.default.fileExists(atPath: manifestURL.path))

    let data = try Data(contentsOf: manifestURL)
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
    #expect(decoded.name == "write-plugin")
    #expect(decoded.pluginProtocolVersion == "1.0")
}
```

Update `buildManifestMissingNameThrows` and `buildManifestMissingProtocolVersionThrows` — remove `Hooks {}` blocks.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ManifestBuilderTests 2>&1 | tail -20`

Expected: compilation errors due to `Hooks` and `HookEntry` still existing

- [ ] **Step 3: Update ManifestBuilder**

In `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift`:

Remove the entire `// MARK: - Hooks` section (lines 108-155): `Hooks`, `HookEntry`, `HookEntryBuilder`.

In `buildManifest`, remove:
- `var hooks: [String: HookConfig] = [:]` (line 183)
- The `Hooks` handling block (lines 192-196)
- `hooks: hooks` from the `PluginManifest` init (line 218)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ManifestBuilderTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift swift/Tests/ManifestBuilderTests.swift
git commit -m "feat: remove Hooks/HookEntry from ManifestBuilder — stages replace hooks"
```

---

### Task 6: Update ConfigBuilder in PiqleyPluginSDK

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/ConfigBuilderTests.swift`

- [ ] **Step 1: Update ConfigBuilderTests**

Remove all tests that use `Rules {}` in `buildConfig`. Keep tests for `RuleEmit`, `ConfigRule`, `MatchField`, and `Values` that don't go through `buildConfig`.

Remove: `configBuilderRules`, `configBuilderValuesAndRules`, `configRuleMultipleEmits`, `configRuleWithWrite`, `configRuleWriteOnly`, `configRuleDefaultsWriteToEmpty`, `configBuilderDependencyRawStrings`, `configBuilderHookScopedRule`.

Keep: `configBuilderValues`, all `ruleEmit*` tests, `matchFieldRead`, `configBuilderWriteSuccess`.

Update `configBuilderValues` — remove `#expect(config.rules.isEmpty)`:

```swift
@Test func configBuilderValues() {
    let config = buildConfig {
        Values {
            "quality" => 80
            "enabled" => true
        }
    }
    #expect(config.values["quality"] == .number(80))
    #expect(config.values["enabled"] == .bool(true))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ConfigBuilderTests 2>&1 | tail -20`

Expected: compilation errors

- [ ] **Step 3: Update ConfigBuilder**

In `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`:

Remove the `// MARK: - Rules block` section (lines 157-188): `Rules`, `ConfigRules`, `RulesBuilder`, `ConfigRulesBuilder`.

In `buildConfig`, remove:
- `var rules: [Rule] = []` (line 206)
- The `Rules` handling block (lines 213-215)
- `rules: rules` from the `PluginConfig` init (line 218)

**Important:** Remove only the `Rules` struct (lines 169-174) and the `ConfigRules` typealias (line 177). **Keep `RulesBuilder` and `ConfigRulesBuilder`** — they will be moved to `StageBuilder.swift` in Task 7. `ConfigRule`, `RuleEmit`, `RuleMatch`, and `ConfigValue` stay in this file as reusable building blocks.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ConfigBuilderTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift swift/Tests/ConfigBuilderTests.swift
git commit -m "feat: remove Rules block from ConfigBuilder — rules move to stage files"
```

---

### Task 7: Add StageBuilder to PiqleyPluginSDK

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/StageBuilder.swift`
- Create: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/StageBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/StageBuilderTests.swift`:

```swift
import Testing
@testable import PiqleyPluginSDK
import PiqleyCore
import Foundation

@Test func buildStageWithAllSections() throws {
    let stage = buildStage {
        PreRules {
            ConfigRule(
                match: .field(.original(.model), pattern: .glob("Canon*")),
                emit: [.keywords(["canon"])]
            )
        }
        Binary(command: "./bin/my-plugin", args: ["--quality", "high"], timeout: 60)
        PostRules {
            ConfigRule(
                match: .field(.dependency("my-plugin", key: "status"), pattern: .exact("done")),
                emit: [.keywords(["processed"])],
                write: [.values(field: "IPTC:Keywords", ["processed"])]
            )
        }
    }
    #expect(stage.preRules?.count == 1)
    #expect(stage.preRules?[0].match.field == "original:TIFF:Model")
    #expect(stage.binary?.command == "./bin/my-plugin")
    #expect(stage.binary?.args == ["--quality", "high"])
    #expect(stage.binary?.timeout == 60)
    #expect(stage.postRules?.count == 1)
    #expect(stage.postRules?[0].write.count == 1)
}

@Test func buildStageBinaryOnly() {
    let stage = buildStage {
        Binary(command: "./bin/tool")
    }
    #expect(stage.preRules == nil)
    #expect(stage.binary?.command == "./bin/tool")
    #expect(stage.postRules == nil)
}

@Test func buildStagePreRulesOnly() {
    let stage = buildStage {
        PreRules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Sony")),
                emit: [.keywords(["sony"])]
            )
        }
    }
    #expect(stage.preRules?.count == 1)
    #expect(stage.binary == nil)
    #expect(stage.postRules == nil)
}

@Test func buildStagePostRulesOnly() {
    let stage = buildStage {
        PostRules {
            ConfigRule(
                match: .field(.original(.make), pattern: .glob("*Nikon*")),
                emit: [.values(field: "tags", ["Nikon"])]
            )
        }
    }
    #expect(stage.preRules == nil)
    #expect(stage.binary == nil)
    #expect(stage.postRules?.count == 1)
}

@Test func buildStageBinaryWithProtocol() {
    let stage = buildStage {
        Binary(command: "./bin/tool", protocol: .pipe, timeout: 120)
    }
    #expect(stage.binary?.pluginProtocol == .pipe)
    #expect(stage.binary?.timeout == 120)
}

@Test func buildStageEmpty() {
    let stage = buildStage {}
    #expect(stage.isEmpty)
}

@Test func buildStageWriteAndRoundTrip() throws {
    let stage = buildStage {
        PreRules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Canon")),
                emit: [.keywords(["canon"])]
            )
        }
        Binary(command: "./bin/tool")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(stage)
    let decoded = try JSONDecoder().decode(StageConfig.self, from: data)
    #expect(decoded.preRules?.count == 1)
    #expect(decoded.binary?.command == "./bin/tool")
    #expect(decoded.postRules == nil)
}

@Test func buildStageMultiplePreRules() {
    let stage = buildStage {
        PreRules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Canon")),
                emit: [.keywords(["canon"])]
            )
            ConfigRule(
                match: .field(.original(.make), pattern: .glob("*Sony*")),
                emit: [.keywords(["sony"])]
            )
        }
    }
    #expect(stage.preRules?.count == 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter StageBuilderTests 2>&1 | tail -20`

Expected: compilation error (StageBuilder doesn't exist)

- [ ] **Step 3: Implement StageBuilder**

Create `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/StageBuilder.swift`:

```swift
import Foundation
import PiqleyCore

// MARK: - StageComponent protocol

public protocol StageComponent: Sendable {}

// MARK: - PreRules

public struct PreRules: StageComponent {
    let rules: [ConfigRule]
    public init(@RulesBuilder _ builder: () -> [ConfigRule]) {
        self.rules = builder()
    }
}

// MARK: - PostRules

public struct PostRules: StageComponent {
    let rules: [ConfigRule]
    public init(@RulesBuilder _ builder: () -> [ConfigRule]) {
        self.rules = builder()
    }
}

// MARK: - Binary

public struct Binary: StageComponent {
    let config: HookConfig

    public init(
        command: String,
        args: [String] = [],
        `protocol`: PluginProtocol? = nil,
        timeout: Int? = nil,
        successCodes: [Int32]? = nil,
        warningCodes: [Int32]? = nil,
        criticalCodes: [Int32]? = nil,
        batchProxy: BatchProxyConfig? = nil
    ) {
        self.config = HookConfig(
            command: command,
            args: args,
            timeout: timeout,
            pluginProtocol: `protocol`,
            successCodes: successCodes,
            warningCodes: warningCodes,
            criticalCodes: criticalCodes,
            batchProxy: batchProxy
        )
    }
}

// MARK: - RulesBuilder (shared between PreRules and PostRules)

@resultBuilder
public enum RulesBuilder {
    public static func buildBlock(_ components: ConfigRule...) -> [ConfigRule] {
        components
    }
    public static func buildExpression(_ expression: ConfigRule) -> ConfigRule { expression }
}

// MARK: - StageComponentBuilder

@resultBuilder
public enum StageComponentBuilder {
    public static func buildBlock(_ components: (any StageComponent)...) -> [any StageComponent] {
        components
    }
    public static func buildExpression(_ expression: any StageComponent) -> any StageComponent { expression }
}

// MARK: - buildStage

public func buildStage(@StageComponentBuilder _ builder: () -> [any StageComponent]) -> StageConfig {
    let components = builder()

    var preRules: [Rule]? = nil
    var binary: HookConfig? = nil
    var postRules: [Rule]? = nil

    for component in components {
        if let component = component as? PreRules {
            preRules = component.rules.map { $0.toRule() }
        } else if let component = component as? Binary {
            binary = component.config
        } else if let component = component as? PostRules {
            postRules = component.rules.map { $0.toRule() }
        }
    }

    return StageConfig(preRules: preRules, binary: binary, postRules: postRules)
}

// MARK: - StageConfig write extension

extension StageConfig {
    /// Writes the stage config to a directory as `stage-<hookName>.json`.
    public func write(to directory: URL, hookName: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let fileName = "\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)"
        try data.write(to: directory.appendingPathComponent(fileName))
    }
}
```

- [ ] **Step 4: Move RulesBuilder from ConfigBuilder to StageBuilder**

In `ConfigBuilder.swift`, remove:
- The `RulesBuilder` enum (lines 179-185)
- The `ConfigRulesBuilder` typealias (line 188)

These are now defined in `StageBuilder.swift` (Step 3 above).

- [ ] **Step 5: Run all SDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add swift/PiqleyPluginSDK/Builders/StageBuilder.swift swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift swift/Tests/StageBuilderTests.swift
git commit -m "feat: add StageBuilder with PreRules/Binary/PostRules DSL"
```

---

### Task 8: Remove `hook` from `RuleMatch` in PiqleyPluginSDK

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/ConfigBuilderTests.swift`

- [ ] **Step 1: Remove hook from RuleMatch**

In `ConfigBuilder.swift`, update `RuleMatch`:

```swift
public struct RuleMatch: Sendable {
    let field: MatchField
    let pattern: MatchPattern

    private init(field: MatchField, pattern: MatchPattern) {
        self.field = field
        self.pattern = pattern
    }

    public static func field(_ field: MatchField, pattern: MatchPattern) -> RuleMatch {
        RuleMatch(field: field, pattern: pattern)
    }

    func toMatchConfig() -> MatchConfig {
        MatchConfig(field: field.encoded, pattern: pattern.encoded)
    }
}
```

- [ ] **Step 2: Fix any remaining `hook:` references in tests**

Check for any remaining `.field(..., hook: ...)` calls across SDK tests and remove the `hook:` parameter.

- [ ] **Step 3: Run all SDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift swift/Tests/ConfigBuilderTests.swift swift/Tests/StageBuilderTests.swift
git commit -m "feat: remove hook from RuleMatch — stage files imply the hook"
```

---

### Task 9: Add `invalidateAll()` to MetadataBuffer in CLI

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/MetadataBuffer.swift`

- [ ] **Step 1: Add invalidateAll()**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/MetadataBuffer.swift`, add after the `flush()` method:

```swift
/// Clear all cached metadata. Call after a binary may have modified files on disk.
/// The dirty set should already be empty (flushed before binary execution).
func invalidateAll() {
    metadata.removeAll()
}
```

- [ ] **Step 2: Run CLI tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter MetadataBuffer 2>&1 | tail -20`

Expected: tests pass (or no MetadataBuffer tests exist yet — that's fine, this is a trivial addition)

- [ ] **Step 3: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/MetadataBuffer.swift
git commit -m "feat: add MetadataBuffer.invalidateAll() for post-binary cache invalidation"
```

---

### Task 10: Remove hook filtering from RuleEvaluator in CLI

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Update RuleEvaluator**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift`:

1. Remove `hook` from `CompiledRule` (line 13):

```swift
struct CompiledRule: Sendable {
    let namespace: String
    let field: String
    let matcher: any TagMatcher & Sendable
    let emitActions: [EmitAction]
    let writeActions: [EmitAction]
}
```

2. Remove `RuleCompilationError.unknownHook` case (line 23).

3. In `init`, remove the hook default (line 46: `let hook = rule.match.hook ?? Hook.preProcess.rawValue`) and the hook validation block (lines 48-56).

4. Remove `hook: hook` from the `CompiledRule` init (line 106-113):

```swift
compiled.append(CompiledRule(
    namespace: namespace,
    field: field,
    matcher: matcher,
    emitActions: emitActions,
    writeActions: writeActions
))
```

5. In `evaluate`, remove the `hook` parameter and the `where rule.hook == hook` filter:

Change signature from:
```swift
func evaluate(
    hook: String,
    state: [String: [String: JSONValue]],
    currentNamespace: [String: JSONValue] = [:],
    metadataBuffer: MetadataBuffer? = nil,
    imageName: String? = nil
) async -> [String: JSONValue]
```

To:
```swift
func evaluate(
    state: [String: [String: JSONValue]],
    currentNamespace: [String: JSONValue] = [:],
    metadataBuffer: MetadataBuffer? = nil,
    imageName: String? = nil
) async -> [String: JSONValue]
```

Change line 188 from `for rule in compiledRules where rule.hook == hook {` to `for rule in compiledRules {`.

- [ ] **Step 2: Update RuleEvaluatorTests**

Remove `hook:` parameter from all `evaluator.evaluate(hook:...)` calls — just pass `state:`, `currentNamespace:`, etc.

Remove any tests that specifically test hook filtering behavior.

- [ ] **Step 3: Run RuleEvaluator tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluator 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/RuleEvaluator.swift Tests/piqleyTests/RuleEvaluatorTests.swift
git commit -m "feat: remove hook filtering from RuleEvaluator — stage files imply the hook"
```

---

### Task 11: Update PluginDiscovery for stage-based loading

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginDiscovery.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginDiscoveryTests.swift`

- [ ] **Step 1: Update PluginDiscoveryTests**

Replace `makePluginsDir` helper to create stage files instead of hooks in manifest:

```swift
func makePluginsDir(plugins: [(name: String, stages: [String])]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-plugins-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    for plugin in plugins {
        let pluginDir = dir.appendingPathComponent(plugin.name)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // Minimal manifest (no hooks)
        let manifest: [String: Any] = [
            "name": plugin.name,
            "pluginProtocolVersion": "1"
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: pluginDir.appendingPathComponent("manifest.json"))
        // Create stage files
        for stage in plugin.stages {
            let stageConfig: [String: Any] = [
                "binary": ["command": "./bin/tool", "args": []]
            ]
            let stageData = try JSONSerialization.data(withJSONObject: stageConfig)
            try stageData.write(to: pluginDir.appendingPathComponent("stage-\(stage).json"))
        }
    }
    return dir
}
```

Update all test calls from `hooks:` to `stages:`. Update `autoAppend` tests to verify stage-based behavior.

Add tests for:

```swift
@Test("discovers stage files")
func testDiscoversStages() throws {
    let dir = try makePluginsDir(plugins: [
        (name: "tagger", stages: ["pre-process", "post-process"])
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let discovery = PluginDiscovery(pluginsDirectory: dir)
    let plugins = try discovery.loadManifests(disabled: [])
    #expect(plugins.count == 1)
    #expect(plugins[0].stages.keys.sorted() == ["post-process", "pre-process"])
    #expect(plugins[0].stages["pre-process"]?.binary?.command == "./bin/tool")
}

@Test("warns on unknown stage name")
func testUnknownStageName() throws {
    let dir = try makePluginsDir(plugins: [
        (name: "weird", stages: ["pre-process", "custom-stage"])
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let discovery = PluginDiscovery(pluginsDirectory: dir)
    let plugins = try discovery.loadManifests(disabled: [])
    // Only known stages are loaded
    #expect(plugins[0].stages.keys.sorted() == ["pre-process"])
}

@Test("autoAppend uses stage files not manifest hooks")
func testAutoAppendFromStages() throws {
    let dir = try makePluginsDir(plugins: [
        (name: "ghost", stages: ["publish"]),
        (name: "365-project", stages: ["post-publish"])
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let discovery = PluginDiscovery(pluginsDirectory: dir)
    let plugins = try discovery.loadManifests(disabled: [])

    var pipeline: [String: [String]] = ["publish": ["existing-plugin"]]
    PluginDiscovery.autoAppend(discovered: plugins, into: &pipeline)

    #expect(pipeline["publish"] == ["existing-plugin", "ghost"])
    #expect(pipeline["post-publish"] == ["365-project"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter PluginDiscovery 2>&1 | tail -20`

Expected: compilation errors (LoadedPlugin doesn't have stages)

- [ ] **Step 3: Update LoadedPlugin and PluginDiscovery**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginDiscovery.swift`:

```swift
import Foundation
import Logging
import PiqleyCore

struct LoadedPlugin: Sendable {
    let name: String
    let directory: URL
    let manifest: PluginManifest
    let stages: [String: StageConfig]
}

struct PluginDiscovery: Sendable {
    let pluginsDirectory: URL
    private let logger = Logger(label: "piqley.discovery")

    /// Loads all plugin manifests and stage configs from `pluginsDirectory`,
    /// skipping disabled plugins and directories without a `manifest.json`.
    func loadManifests(disabled: [String]) throws -> [LoadedPlugin] {
        guard FileManager.default.fileExists(atPath: pluginsDirectory.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))

        return try contents.compactMap { url -> LoadedPlugin? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            guard !disabled.contains(name) else { return nil }
            let manifestURL = url.appendingPathComponent(PluginFile.manifest)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

            // Discover stage files
            let stages = loadStages(from: url, knownHooks: knownHooks)

            let dataDir = url.appendingPathComponent(PluginDirectory.data)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            return LoadedPlugin(name: name, directory: url, manifest: manifest, stages: stages)
        }.sorted { $0.name < $1.name }
    }

    /// Scans a plugin directory for `stage-*.json` files and parses them.
    private func loadStages(from pluginDir: URL, knownHooks: Set<String>) -> [String: StageConfig] {
        var stages: [String: StageConfig] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pluginDir, includingPropertiesForKeys: nil
        ) else { return stages }

        for file in files {
            let filename = file.lastPathComponent
            guard filename.hasPrefix(PluginFile.stagePrefix),
                  filename.hasSuffix(PluginFile.stageSuffix) else { continue }

            let stageName = String(
                filename.dropFirst(PluginFile.stagePrefix.count)
                    .dropLast(PluginFile.stageSuffix.count)
            )

            guard knownHooks.contains(stageName) else {
                logger.warning("Plugin '\(pluginDir.lastPathComponent)' has unknown stage '\(stageName)' — ignored")
                continue
            }

            do {
                let data = try Data(contentsOf: file)
                let config = try JSONDecoder().decode(StageConfig.self, from: data)
                if config.isEmpty {
                    logger.warning("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)' is empty — ignored")
                    continue
                }
                // Validate batchProxy + json protocol incompatibility
                if let binary = config.binary, let batchProxy = binary.batchProxy {
                    _ = batchProxy
                    if binary.pluginProtocol == .json {
                        logger.warning("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)': batchProxy is not compatible with json protocol — skipped")
                        continue
                    }
                }
                stages[stageName] = config
            } catch {
                logger.warning("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)' has malformed JSON — skipped")
            }
        }

        return stages
    }

    /// Appends newly discovered plugins to pipeline hook lists.
    /// Plugins already listed (by name, ignoring any suffixes) are not duplicated.
    /// Only adds to hooks the plugin has stage files for.
    static func autoAppend(discovered: [LoadedPlugin], into pipeline: inout [String: [String]]) {
        for plugin in discovered {
            for hookName in Hook.canonicalOrder.map(\.rawValue) {
                guard plugin.stages[hookName] != nil else { continue }
                var list = pipeline[hookName] ?? []
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

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter PluginDiscovery 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Plugins/PluginDiscovery.swift Tests/piqleyTests/PluginDiscoveryTests.swift
git commit -m "feat: stage-based plugin discovery — scan for stage-*.json files"
```

---

### Task 12: Rework PipelineOrchestrator for stage-based execution

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`

- [ ] **Step 1: Update runPluginHook**

Replace the `runPluginHook` method to use stage-based execution with pre/post rules and buffer invalidation. The key changes:

1. `loadPlugin` must now return a `LoadedPlugin` with `stages` — update it to scan for stage files.
2. Replace `evaluateRules` + binary execution with the 8-step flow from the spec.
3. Remove references to `manifest.hooks`.

Updated `loadPlugin` — reuse `PluginDiscovery.loadStages` to avoid duplicating stage-scanning logic. First, make `loadStages` a `static` method on `PluginDiscovery` so the orchestrator can call it:

In `PluginDiscovery.swift` (from Task 11), change `private func loadStages` to `static func loadStages` and remove the `self.logger` reference (pass a logger parameter or use a static logger):

```swift
static func loadStages(from pluginDir: URL, knownHooks: Set<String>, logger: Logger) -> [String: StageConfig] {
```

Then update `loadPlugin` in the orchestrator:

```swift
private func loadPlugin(named name: String) throws -> LoadedPlugin? {
    let pluginDir = pluginsDirectory.appendingPathComponent(name)
    let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

    let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
    let stages = PluginDiscovery.loadStages(from: pluginDir, knownHooks: knownHooks, logger: logger)

    return LoadedPlugin(name: name, directory: pluginDir, manifest: manifest, stages: stages)
}
```

Updated `runPluginHook` — full replacement:

```swift
private func runPluginHook(
    _ ctx: HookContext,
    ruleEvaluatorCache: inout [String: RuleEvaluator]
) async throws -> HookResult {
    guard let loadedPlugin = try loadPlugin(named: ctx.pluginName) else {
        logger.error("Plugin '\(ctx.pluginName)' not found in \(pluginsDirectory.path)")
        return .pluginNotFound
    }

    // Look up stage config for this hook
    guard let stageConfig = loadedPlugin.stages[ctx.hook] else {
        logger.debug("[\(ctx.pluginName)] hook '\(ctx.hook)': no stage file — skipping")
        return .skipped
    }

    // Fetch secrets
    let secrets: [String: String]
    do {
        secrets = try fetchSecrets(for: loadedPlugin)
    } catch {
        return .secretMissing
    }

    let execLogPath = pluginsDirectory
        .appendingPathComponent(ctx.pluginName)
        .appendingPathComponent(PluginFile.executionLog)
    try FileManager.default.createDirectory(
        at: execLogPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let pluginConfigURL = pluginsDirectory
        .appendingPathComponent(ctx.pluginName)
        .appendingPathComponent(PluginFile.config)
    let pluginConfig = PluginConfig.load(fromIfExists: pluginConfigURL)
    let manifestDeps = loadedPlugin.manifest.dependencyNames

    let imageURLs = Dictionary(uniqueKeysWithValues: ctx.imageFiles.map {
        ($0.lastPathComponent, $0)
    })
    let buffer = MetadataBuffer(imageURLs: imageURLs)

    // Step 1: Pre-rules
    var preRulesDidRun = false
    if let preRules = stageConfig.preRules, !preRules.isEmpty {
        do {
            preRulesDidRun = try await evaluateRuleset(
                rules: preRules, ctx: ctx, manifestDeps: manifestDeps,
                buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
                cacheKey: "\(ctx.pluginName):pre:\(ctx.hook)"
            )
        } catch {
            logger.error("[\(ctx.pluginName)] pre-rule compilation failed: \(error.localizedDescription)")
            return .ruleCompilationFailed
        }
    }

    // Step 2: Flush pre-rule write actions
    await buffer.flush()

    // Step 3: Binary execution
    var binaryDidRun = false
    if stageConfig.binary?.command != nil {
        let result = try await runBinary(
            ctx, loadedPlugin: loadedPlugin,
            secrets: secrets, pluginConfig: pluginConfig,
            hookConfig: stageConfig.binary, manifestDeps: manifestDeps,
            rulesDidRun: preRulesDidRun, execLogPath: execLogPath
        )
        switch result {
        case .success, .warning:
            binaryDidRun = true
        case .critical, .pluginNotFound, .secretMissing, .ruleCompilationFailed:
            return result
        case .skipped:
            break
        }
    }

    // Step 4: Invalidate buffer cache (binary may have modified files)
    if binaryDidRun {
        await buffer.invalidateAll()
    }

    // Step 5: Post-rules
    if let postRules = stageConfig.postRules, !postRules.isEmpty {
        do {
            _ = try await evaluateRuleset(
                rules: postRules, ctx: ctx, manifestDeps: manifestDeps,
                buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
                cacheKey: "\(ctx.pluginName):post:\(ctx.hook)"
            )
        } catch {
            logger.error("[\(ctx.pluginName)] post-rule compilation failed: \(error.localizedDescription)")
            return .ruleCompilationFailed
        }
    }

    // Step 6: Flush post-rule write actions
    await buffer.flush()

    if !preRulesDidRun && !binaryDidRun && (stageConfig.postRules ?? []).isEmpty {
        return .skipped
    }
    return .success
}
```

Add a new `evaluateRuleset` helper (replaces the old `evaluateRules`):

```swift
private func evaluateRuleset(
    rules: [Rule],
    ctx: HookContext,
    manifestDeps: [String],
    buffer: MetadataBuffer,
    ruleEvaluatorCache: inout [String: RuleEvaluator],
    cacheKey: String
) async throws -> Bool {
    let evaluator: RuleEvaluator
    if let cached = ruleEvaluatorCache[cacheKey] {
        evaluator = cached
    } else {
        evaluator = try RuleEvaluator(
            rules: rules,
            nonInteractive: ctx.nonInteractive,
            logger: logger
        )
        ruleEvaluatorCache[cacheKey] = evaluator
    }

    var didRun = false
    for imageName in await ctx.stateStore.allImageNames {
        let resolved = await ctx.stateStore.resolve(
            image: imageName, dependencies: manifestDeps + [ReservedName.original, ctx.pluginName]
        )
        let currentNamespace = resolved[ctx.pluginName] ?? [:]
        let ruleOutput = await evaluator.evaluate(
            state: resolved, currentNamespace: currentNamespace,
            metadataBuffer: buffer, imageName: imageName
        )
        if ruleOutput != currentNamespace {
            await ctx.stateStore.setNamespace(
                image: imageName, plugin: ctx.pluginName, values: ruleOutput
            )
            didRun = true
        }
    }

    return didRun
}
```

Remove the old `evaluateRules` method.

- [ ] **Step 2: Run full CLI test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: compilation may fail — fix any remaining references to old APIs (`manifest.hooks`, `hook:` parameter in evaluator calls, etc.)

- [ ] **Step 3: Fix compilation errors if any**

Common fixes:
- Any remaining `hook:` parameter in `evaluator.evaluate()` calls
- Any `pluginConfig.rules` references
- Any `manifest.hooks` references

- [ ] **Step 4: Run tests again**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift
git commit -m "feat: rework PipelineOrchestrator for stage-based execution with pre/post rules"
```

---

### Task 13: Update `piqley plugin init` for stage-based output

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/PluginCommand.swift`

- [ ] **Step 1: Update InitSubcommand.execute**

Replace the manifest and config generation to:
1. Build a manifest without hooks
2. Build a config without rules (values only)
3. Generate `stage-pre-process.json` with example rules (if `includeExamples`)
4. Generate `stage-post-process.json` with example rules (if `includeExamples`)

Key changes:

Manifest:
```swift
let manifest: PluginManifest = if includeExamples {
    try buildManifest {
        Name(name)
        ProtocolVersion("1")
        try PluginVersion("0.1.0")
        ConfigEntries {
            Value("outputQuality", type: .int, default: 85)
            Value("tagPrefix", type: .string, default: "auto")
            Secret("API_KEY", type: .string)
        }
    }
} else {
    try buildManifest {
        Name(name)
        ProtocolVersion("1")
    }
}
```

Config (no rules):
```swift
let config: PluginConfig = if includeExamples {
    buildConfig {
        Values {
            "outputQuality" => 85
            "tagPrefix" => "auto"
        }
    }
} else {
    buildConfig {}
}
```

Stage files (if includeExamples):
```swift
if includeExamples {
    let preProcessStage = buildStage {
        PreRules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Canon EOS R5")),
                emit: [.values(field: "tags", ["Canon", "EOS R5"])]
            )
            ConfigRule(
                match: .field(.original(.lensModel), pattern: .glob("RF*")),
                emit: [.values(field: "tags", ["RF Mount"])]
            )
            ConfigRule(
                match: .field(.original(.iso), pattern: .regex("^(3200|6400|12800|25600)$")),
                emit: [.values(field: "tags", ["High ISO"])]
            )
            ConfigRule(
                match: .field(.original(.focalLength), pattern: .regex("^(85|105|135)$")),
                emit: [.keywords(["Portrait"])]
            )
        }
    }
    let preProcessInstructions = """
    Pre-process rules run before any binary. Match against original image metadata \
    and emit tags/keywords to your plugin's namespace. All rules in this file run \
    during the pre-process stage.
    """
    try Self.writeJSON(preProcessStage, instructions: preProcessInstructions,
                       to: pluginDir, fileName: "stage-pre-process.json")

    let postProcessStage = buildStage {
        PostRules {
            ConfigRule(
                match: .field(.dependency(name, key: "tags"), pattern: .exact("Kodak")),
                emit: [
                    .remove(field: "tags", ["Kodak"]),
                    .values(field: "tags", ["Piqley Emulsions, LLC"]),
                ]
            )
            ConfigRule(
                match: .field(.original(.make), pattern: .glob("*Canon*")),
                emit: [.keywords(["Canon"])],
                write: [.values(field: "IPTC:Keywords", ["Canon", "piqley-processed"])]
            )
        }
    }
    let postProcessInstructions = """
    Post-process rules run after any binary. You can match against your own plugin's \
    output from pre-process using '<plugin-name>:<field>' syntax. Write actions modify \
    the image file's metadata directly.
    """
    try Self.writeJSON(postProcessStage, instructions: postProcessInstructions,
                       to: pluginDir, fileName: "stage-post-process.json")
}
```

Update the manifest instructions text to remove hook references. Update the config instructions to remove rule references.

- [ ] **Step 2: Run CLI tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 3: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/CLI/PluginCommand.swift
git commit -m "feat: update plugin init to generate stage files instead of hooks/rules"
```

---

### Task 14: Cross-repo verification

- [ ] **Step 1: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 2: Run PiqleyPluginSDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 3: Run piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 4: Build release**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build -c release 2>&1 | tail -10`

Expected: clean build

---

## Follow-up Work (out of scope for this plan)

- **`stage.schema.json`**: Create JSON Schema for `StageConfig` validation. This is part of the SDK Build & Packaging spec (`2026-03-18-sdk-build-packaging-design.md`) and will be addressed in that plan alongside `manifest.schema.json` and `config.schema.json` updates.
- **Legacy `rules` warning in config.json**: The spec says the CLI should warn if a `config.json` contains a `rules` key. Since `PluginConfig` now silently ignores the key (via `CodingKeys` not listing it), a warning can be added to `PluginConfig.load(fromIfExists:)` by checking raw JSON for a `"rules"` key before decoding. This is a polish item that can be done as a follow-up.
