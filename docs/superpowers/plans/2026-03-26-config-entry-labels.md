# Config Entry Labels and Descriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add human-readable labels and descriptions to plugin config entries so users see friendly names during setup instead of raw field identifiers.

**Architecture:** A new `ConfigMetadata` struct in piqley-core groups `label` and `description` as optional fields on each `ConfigEntry` case. The JSON remains flat (label/description alongside key/type). The CLI reads `displayLabel` and `metadata.description` to render user-friendly prompts.

**Tech Stack:** Swift, JSON Schema, Swift Testing framework

---

### Task 1: Add ConfigMetadata struct and update ConfigEntry in piqley-core

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/ConfigEntry.swift`

- [ ] **Step 1: Add ConfigMetadata struct above the ConfigEntry enum**

Add this struct before `public enum ConfigEntry`:

```swift
/// Display metadata for a configuration entry shown during plugin setup.
public struct ConfigMetadata: Codable, Sendable, Equatable {
    public let label: String?
    public let description: String?

    public init(label: String? = nil, description: String? = nil) {
        self.label = label
        self.description = description
    }
}
```

- [ ] **Step 2: Update ConfigEntry enum cases to include metadata**

Change the enum cases from:

```swift
case value(key: String, type: ConfigValueType, value: JSONValue)
case secret(secretKey: String, type: ConfigValueType)
```

to:

```swift
case value(key: String, type: ConfigValueType, value: JSONValue, metadata: ConfigMetadata)
case secret(secretKey: String, type: ConfigValueType, metadata: ConfigMetadata)
```

- [ ] **Step 3: Add label and description to CodingKeys**

Update the CodingKeys enum from:

```swift
private enum CodingKeys: String, CodingKey {
    case key
    case secretKey = "secret_key"
    case type
    case value
}
```

to:

```swift
private enum CodingKeys: String, CodingKey {
    case key
    case secretKey = "secret_key"
    case type
    case value
    case label
    case description
}
```

- [ ] **Step 4: Update init(from decoder:) to decode metadata**

In the `hasKey` branch, after decoding key/type/value, add metadata decoding:

```swift
if hasKey {
    let key = try container.decode(String.self, forKey: .key)
    let type_ = try container.decode(ConfigValueType.self, forKey: .type)
    let value = try container.decode(JSONValue.self, forKey: .value)
    let label = try container.decodeIfPresent(String.self, forKey: .label)
    let description = try container.decodeIfPresent(String.self, forKey: .description)
    self = .value(key: key, type: type_, value: value, metadata: ConfigMetadata(label: label, description: description))
}
```

In the `hasSecretKey` branch:

```swift
} else if hasSecretKey {
    let secretKey = try container.decode(String.self, forKey: .secretKey)
    let type_ = try container.decode(ConfigValueType.self, forKey: .type)
    let label = try container.decodeIfPresent(String.self, forKey: .label)
    let description = try container.decodeIfPresent(String.self, forKey: .description)
    self = .secret(secretKey: secretKey, type: type_, metadata: ConfigMetadata(label: label, description: description))
}
```

- [ ] **Step 5: Update encode(to encoder:) to encode metadata**

Update the `.value` case:

```swift
case .value(let key, let type_, let value, let metadata):
    try container.encode(key, forKey: .key)
    try container.encode(type_, forKey: .type)
    try container.encode(value, forKey: .value)
    try container.encodeIfPresent(metadata.label, forKey: .label)
    try container.encodeIfPresent(metadata.description, forKey: .description)
```

Update the `.secret` case:

```swift
case .secret(let secretKey, let type_, let metadata):
    try container.encode(secretKey, forKey: .secretKey)
    try container.encode(type_, forKey: .type)
    try container.encodeIfPresent(metadata.label, forKey: .label)
    try container.encodeIfPresent(metadata.description, forKey: .description)
```

- [ ] **Step 6: Add displayLabel convenience property**

Add this after the `encode` method, inside the `ConfigEntry` enum:

```swift
/// The user-facing label for this entry, falling back to the raw key if no label is set.
public var displayLabel: String {
    switch self {
    case .value(let key, _, _, let metadata):
        return (metadata.label?.isEmpty == false) ? metadata.label! : key
    case .secret(let secretKey, _, let metadata):
        return (metadata.label?.isEmpty == false) ? metadata.label! : secretKey
    }
}
```

- [ ] **Step 7: Build piqley-core to verify compilation**

Run from `/Users/wash/Developer/tools/piqley/piqley-core`:

```bash
swift build 2>&1 | tail -5
```

Expected: compilation errors in piqley-core tests and any downstream consumers that pattern-match on `ConfigEntry` cases (these will be fixed in subsequent tasks). The library itself should compile.

- [ ] **Step 8: Commit**

```
feat(core): add ConfigMetadata struct with label and description to ConfigEntry
```

### Task 2: Fix PluginManifest pattern matches in piqley-core

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift:106-121`

The `secretKeys` and `valueEntries` computed properties pattern-match on `ConfigEntry` and need to account for the new `metadata` parameter.

- [ ] **Step 1: Update secretKeys computed property**

Change from:

```swift
public var secretKeys: [String] {
    config.compactMap { entry in
        if case .secret(let key, _) = entry { return key }
        return nil
    }
}
```

to:

```swift
public var secretKeys: [String] {
    config.compactMap { entry in
        if case .secret(let key, _, _) = entry { return key }
        return nil
    }
}
```

- [ ] **Step 2: Update valueEntries computed property**

Change from:

```swift
public var valueEntries: [(key: String, type: ConfigValueType, value: JSONValue)] {
    config.compactMap { entry in
        if case .value(let key, let type_, let value) = entry {
            return (key: key, type: type_, value: value)
        }
        return nil
    }
}
```

to:

```swift
public var valueEntries: [(key: String, type: ConfigValueType, value: JSONValue)] {
    config.compactMap { entry in
        if case .value(let key, let type_, let value, _) = entry {
            return (key: key, type: type_, value: value)
        }
        return nil
    }
}
```

- [ ] **Step 3: Search for any other pattern matches on ConfigEntry in piqley-core**

Run from `/Users/wash/Developer/tools/piqley/piqley-core`:

```bash
grep -rn "case \.value\|case \.secret" Sources/ --include="*.swift"
```

Fix any remaining matches that don't account for the new metadata parameter.

- [ ] **Step 4: Build piqley-core**

Run from `/Users/wash/Developer/tools/piqley/piqley-core`:

```bash
swift build 2>&1 | tail -5
```

Expected: Build Succeeded (library sources only; test targets may still fail if they exist).

- [ ] **Step 5: Commit**

```
fix(core): update ConfigEntry pattern matches for metadata parameter
```

### Task 3: Update piqley-core tests

**Files:**
- Search for and modify any test files in `/Users/wash/Developer/tools/piqley/piqley-core/Tests/` that construct or pattern-match `ConfigEntry`

- [ ] **Step 1: Find all test files referencing ConfigEntry**

Run from `/Users/wash/Developer/tools/piqley/piqley-core`:

```bash
grep -rln "ConfigEntry\|\.value(\|\.secret(" Tests/ --include="*.swift"
```

- [ ] **Step 2: Update all ConfigEntry constructors in tests**

Every `.value(key:type:value:)` call needs a `metadata:` parameter added. Use `metadata: ConfigMetadata()` for existing tests that don't need labels:

```swift
// Before:
.value(key: "api-url", type: .string, value: .null)
// After:
.value(key: "api-url", type: .string, value: .null, metadata: ConfigMetadata())
```

Every `.secret(secretKey:type:)` call needs a `metadata:` parameter:

```swift
// Before:
.secret(secretKey: "api-token", type: .string)
// After:
.secret(secretKey: "api-token", type: .string, metadata: ConfigMetadata())
```

- [ ] **Step 3: Add tests for ConfigMetadata decoding**

Add a test that verifies JSON with label and description decodes correctly:

```swift
@Test("decodes config entry with label and description")
func decodesMetadata() throws {
    let json = """
    {"key": "api-url", "type": "string", "value": "", "label": "API URL", "description": "The base URL for the API"}
    """
    let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
    guard case .value(_, _, _, let metadata) = entry else {
        Issue.record("Expected value entry")
        return
    }
    #expect(metadata.label == "API URL")
    #expect(metadata.description == "The base URL for the API")
}
```

- [ ] **Step 4: Add test for missing label/description decoding**

```swift
@Test("decodes config entry without label or description")
func decodesWithoutMetadata() throws {
    let json = """
    {"key": "api-url", "type": "string", "value": ""}
    """
    let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
    guard case .value(_, _, _, let metadata) = entry else {
        Issue.record("Expected value entry")
        return
    }
    #expect(metadata.label == nil)
    #expect(metadata.description == nil)
}
```

- [ ] **Step 5: Add test for displayLabel fallback**

```swift
@Test("displayLabel falls back to key when label is nil")
func displayLabelFallback() {
    let entry = ConfigEntry.value(key: "BASE_URL", type: .string, value: .string(""), metadata: ConfigMetadata())
    #expect(entry.displayLabel == "BASE_URL")
}

@Test("displayLabel falls back to key when label is empty")
func displayLabelFallbackEmpty() {
    let entry = ConfigEntry.value(key: "BASE_URL", type: .string, value: .string(""), metadata: ConfigMetadata(label: ""))
    #expect(entry.displayLabel == "BASE_URL")
}

@Test("displayLabel uses label when present")
func displayLabelUsesLabel() {
    let entry = ConfigEntry.value(key: "BASE_URL", type: .string, value: .string(""), metadata: ConfigMetadata(label: "Base URL"))
    #expect(entry.displayLabel == "Base URL")
}

@Test("displayLabel works for secret entries")
func displayLabelSecret() {
    let entry = ConfigEntry.secret(secretKey: "API_KEY", type: .string, metadata: ConfigMetadata(label: "API Key"))
    #expect(entry.displayLabel == "API Key")
}
```

- [ ] **Step 6: Add test for encoding metadata**

```swift
@Test("encodes config entry with label and description")
func encodesMetadata() throws {
    let entry = ConfigEntry.value(
        key: "api-url", type: .string, value: .string(""),
        metadata: ConfigMetadata(label: "API URL", description: "The base URL")
    )
    let data = try JSONEncoder().encode(entry)
    let dict = try JSONDecoder().decode([String: String].self, from: data)
    #expect(dict["label"] == "API URL")
    #expect(dict["description"] == "The base URL")
}

@Test("omits label and description from encoding when nil")
func encodesWithoutMetadata() throws {
    let entry = ConfigEntry.value(
        key: "api-url", type: .string, value: .string(""),
        metadata: ConfigMetadata()
    )
    let data = try JSONEncoder().encode(entry)
    let json = String(data: data, encoding: .utf8)!
    #expect(!json.contains("label"))
    #expect(!json.contains("description"))
}
```

- [ ] **Step 7: Run piqley-core tests**

Run from `/Users/wash/Developer/tools/piqley/piqley-core`:

```bash
swift test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 8: Commit**

```
test(core): update and add ConfigEntry tests for metadata fields
```

### Task 4: Update manifest.schema.json in piqley-plugin-sdk

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/schemas/manifest.schema.json:35-56`

- [ ] **Step 1: Add label and description to the value entry variant**

Change the value entry object in `$defs.configEntry.oneOf[0]` from:

```json
{
  "type": "object",
  "required": ["key", "type"],
  "properties": {
    "key": { "type": "string" },
    "type": { "enum": ["string", "int", "float", "bool"] },
    "value": {}
  },
  "additionalProperties": false
}
```

to:

```json
{
  "type": "object",
  "required": ["key", "type"],
  "properties": {
    "key": { "type": "string" },
    "type": { "enum": ["string", "int", "float", "bool"] },
    "value": {},
    "label": { "type": "string" },
    "description": { "type": "string" }
  },
  "additionalProperties": false
}
```

- [ ] **Step 2: Add label and description to the secret entry variant**

Change the secret entry object in `$defs.configEntry.oneOf[1]` from:

```json
{
  "type": "object",
  "required": ["secret_key", "type"],
  "properties": {
    "secret_key": { "type": "string" },
    "type": { "enum": ["string", "int", "float", "bool"] }
  },
  "additionalProperties": false
}
```

to:

```json
{
  "type": "object",
  "required": ["secret_key", "type"],
  "properties": {
    "secret_key": { "type": "string" },
    "type": { "enum": ["string", "int", "float", "bool"] },
    "label": { "type": "string" },
    "description": { "type": "string" }
  },
  "additionalProperties": false
}
```

- [ ] **Step 3: Commit**

```
feat(sdk): add optional label and description to config entry schema
```

### Task 5: Update PluginSetupScanner prompts in piqley-cli

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginSetupScanner.swift`

- [ ] **Step 1: Update Phase 1 loop to extract metadata and use displayLabel**

Change the Phase 1 loop body (lines 38-49) from:

```swift
for entry in plugin.manifest.config {
    guard case let .value(key, type, defaultValue) = entry else { continue }
    if skipValueKeys.contains(key) {
        continue
    }
    if !force, let existing = baseConfig.values[key] {
        print("[\(plugin.name)] \(key) already set to: \(displayValue(existing))")
        continue
    }
    let resolved = promptForValue(pluginName: plugin.name, key: key, type: type, defaultValue: defaultValue)
    baseConfig.values[key] = resolved
}
```

to:

```swift
for entry in plugin.manifest.config {
    guard case let .value(key, type, defaultValue, _) = entry else { continue }
    if skipValueKeys.contains(key) {
        continue
    }
    if !force, let existing = baseConfig.values[key] {
        print("[\(plugin.name)] \(entry.displayLabel) already set to: \(displayValue(existing))")
        continue
    }
    let resolved = promptForValue(pluginName: plugin.name, entry: entry, key: key, type: type, defaultValue: defaultValue)
    baseConfig.values[key] = resolved
}
```

- [ ] **Step 2: Update Phase 2 loop to use displayLabel**

Change the Phase 2 loop body (lines 52-71) from:

```swift
for entry in plugin.manifest.config {
    guard case let .secret(secretKey, _) = entry else { continue }
    if skipSecretKeys.contains(secretKey) {
        continue
    }
    let alias = defaultSecretAlias(pluginIdentifier: plugin.identifier, secretKey: secretKey)

    // Check if we already have this alias mapped and the secret exists
    if let existingAlias = baseConfig.secrets[secretKey] {
        if (try? secretStore.get(key: existingAlias)) != nil {
            print("[\(plugin.name)] \(secretKey) (secret) already set")
            continue
        }
    }

    // Prompt for secret value and store under alias
    let value = promptForSecret(pluginName: plugin.name, key: secretKey)
    try secretStore.set(key: alias, value: value)
    baseConfig.secrets[secretKey] = alias
}
```

to:

```swift
for entry in plugin.manifest.config {
    guard case let .secret(secretKey, _, _) = entry else { continue }
    if skipSecretKeys.contains(secretKey) {
        continue
    }
    let alias = defaultSecretAlias(pluginIdentifier: plugin.identifier, secretKey: secretKey)

    // Check if we already have this alias mapped and the secret exists
    if let existingAlias = baseConfig.secrets[secretKey] {
        if (try? secretStore.get(key: existingAlias)) != nil {
            print("[\(plugin.name)] \(entry.displayLabel) (secret) already set")
            continue
        }
    }

    // Prompt for secret value and store under alias
    let value = promptForSecret(pluginName: plugin.name, entry: entry, key: secretKey)
    try secretStore.set(key: alias, value: value)
    baseConfig.secrets[secretKey] = alias
}
```

- [ ] **Step 3: Update promptForValue signature and body**

Change the method from:

```swift
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
```

to:

```swift
private mutating func promptForValue(
    pluginName: String, entry: ConfigEntry, key: String, type: ConfigValueType, defaultValue: JSONValue
) -> JSONValue {
    let hasDefault = defaultValue != .null && defaultValue != .string("")
    while true {
        if case .value(_, _, _, let metadata) = entry,
           let desc = metadata.description, !desc.isEmpty {
            print("  \(desc)")
        }
        if hasDefault {
            let defaultStr = displayValue(defaultValue)
            print("[\(pluginName)] \(entry.displayLabel) [\(defaultStr)]: ", terminator: "")
        } else {
            print("[\(pluginName)] \(entry.displayLabel): ", terminator: "")
        }
```

The rest of the method body (input reading, parsing, validation) stays the same.

- [ ] **Step 4: Update promptForSecret signature and body**

Change the method from:

```swift
private mutating func promptForSecret(pluginName: String, key: String) -> String {
    while true {
        print("[\(pluginName)] \(key) (secret): ", terminator: "")
```

to:

```swift
private mutating func promptForSecret(pluginName: String, entry: ConfigEntry, key: String) -> String {
    while true {
        if case .secret(_, _, let metadata) = entry,
           let desc = metadata.description, !desc.isEmpty {
            print("  \(desc)")
        }
        print("[\(pluginName)] \(entry.displayLabel) (secret): ", terminator: "")
```

The rest of the method body stays the same.

- [ ] **Step 5: Search for any other pattern matches on ConfigEntry in piqley-cli**

Run from `/Users/wash/Developer/tools/piqley/piqley-cli`:

```bash
grep -rn "case \.value\|case \.secret\|case let \.value\|case let \.secret" Sources/ --include="*.swift"
```

Fix any remaining matches that don't account for the new metadata parameter.

- [ ] **Step 6: Build piqley-cli**

Run from `/Users/wash/Developer/tools/piqley/piqley-cli`:

```bash
swift build 2>&1 | tail -10
```

Expected: Build Succeeded.

- [ ] **Step 7: Commit**

```
feat(cli): use displayLabel and description in plugin setup prompts
```

### Task 6: Update piqley-cli tests

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginSetupScannerTests.swift`

- [ ] **Step 1: Update all existing ConfigEntry constructors in tests**

Every `.value(key:type:value:)` call needs `metadata: ConfigMetadata()` appended. Every `.secret(secretKey:type:)` call needs `metadata: ConfigMetadata()` appended.

For example, in `promptRequiredValue()`:

```swift
// Before:
config: [.value(key: "api-url", type: .string, value: .null)],
// After:
config: [.value(key: "api-url", type: .string, value: .null, metadata: ConfigMetadata())],
```

In `promptMissingSecret()`:

```swift
// Before:
config: [.secret(secretKey: "api-token", type: .string)],
// After:
config: [.secret(secretKey: "api-token", type: .string, metadata: ConfigMetadata())],
```

Apply this to all 10 existing tests.

- [ ] **Step 2: Add import for ConfigMetadata at top of test file**

Ensure `import PiqleyCore` is already present (it is). `ConfigMetadata` is public and will be accessible through that import.

- [ ] **Step 3: Run existing tests to verify they still pass**

Run from `/Users/wash/Developer/tools/piqley/piqley-cli`:

```bash
swift test --filter PluginSetupScannerTests 2>&1 | tail -20
```

Expected: All 10 existing tests pass.

- [ ] **Step 4: Add test for label appearing in prompt output**

Add a new test that verifies the label is used in the prompt. Since we can't easily capture stdout in Swift Testing, verify the functional behavior works: create an entry with a label, run the scanner, confirm values are stored correctly. The label rendering is a presentation concern tested by building and running manually.

```swift
@Test("config entry with label stores value under original key")
func labeledValueStoresUnderKey() throws {
    let configDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: configDir) }
    let manifest = PluginManifest(
        identifier: "com.test.test-plugin",
        name: "test-plugin",
        pluginSchemaVersion: "1",
        config: [.value(key: "BASE_URL", type: .string, value: .null, metadata: ConfigMetadata(label: "Site URL", description: "Your site's base URL"))],
        setup: nil
    )
    let dir = try makePluginDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
    let secretStore = MockSecretStore()
    let configStore = makeConfigStore(configDir)
    let inputSource = MockInputSource(responses: ["https://example.com"])
    var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource)
    try scanner.scan(plugin: plugin)

    let config = try configStore.load(for: "com.test.test-plugin")
    #expect(config?.values["BASE_URL"] == JSONValue.string("https://example.com"))
}
```

- [ ] **Step 5: Add test for labeled secret storing under original key**

```swift
@Test("secret entry with label stores under original key alias")
func labeledSecretStoresUnderKey() throws {
    let configDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: configDir) }
    let manifest = PluginManifest(
        identifier: "com.test.test-plugin",
        name: "test-plugin",
        pluginSchemaVersion: "1",
        config: [.secret(secretKey: "ADMIN_API_KEY", type: .string, metadata: ConfigMetadata(label: "Admin API Key", description: "Found in Ghost admin panel"))],
        setup: nil
    )
    let dir = try makePluginDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
    let secretStore = MockSecretStore()
    let configStore = makeConfigStore(configDir)
    let inputSource = MockInputSource(responses: ["my-secret"])
    var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource)
    try scanner.scan(plugin: plugin)

    let alias = "com.test.test-plugin-ADMIN_API_KEY"
    let stored = try secretStore.get(key: alias)
    #expect(stored == "my-secret")
    let config = try configStore.load(for: "com.test.test-plugin")
    #expect(config?.secrets["ADMIN_API_KEY"] == alias)
}
```

- [ ] **Step 6: Run all CLI tests**

Run from `/Users/wash/Developer/tools/piqley/piqley-cli`:

```bash
swift test --filter PluginSetupScannerTests 2>&1 | tail -20
```

Expected: All tests pass (original 10 + 2 new).

- [ ] **Step 7: Commit**

```
test(cli): update and add PluginSetupScanner tests for config entry labels
```

### Task 7: Final verification

- [ ] **Step 1: Build all three repos**

Run these sequentially:

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift build
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build
```

Expected: Both build successfully.

- [ ] **Step 2: Run all tests across repos**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift test
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test
```

Expected: All tests pass in both repos.
