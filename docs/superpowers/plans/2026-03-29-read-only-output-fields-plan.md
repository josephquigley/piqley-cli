# Read-Only Output Fields Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `readOnly` flag to plugin fields so computed output fields and image metadata fields cannot be targeted by emit/write actions in the rules editor.

**Architecture:** Add `readOnly: Bool` to `ConsumedField` (PiqleyCore) and `FieldInfo` (PiqleyCore). Rename consumed field types to generic field types. Add `Outputs` DSL entry to the plugin SDK. Filter read-only fields from emit/write targets in the CLI rules editor with a TUI hint.

**Tech Stack:** Swift, PiqleyCore, PiqleyPluginSDK, piqley CLI

---

### Task 1: Add `readOnly` to `ConsumedField` (PiqleyCore)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/ConsumedField.swift`

- [ ] **Step 1: Add `readOnly` property to `ConsumedField`**

Replace the entire file:

```swift
/// A state field that a plugin declares it works with.
///
/// Consumed fields are surfaced in the rules editor for:
/// 1. The plugin's own rules (so you can write `self:tags` rules)
/// 2. Downstream plugins (so they can reference upstream fields before any rules exist)
///
/// Fields marked `readOnly` can be used in match conditions but cannot be
/// targeted by emit or write actions.
///
/// ```json
/// { "name": "tags", "type": "csv", "description": "Comma-separated tag names", "readOnly": false }
/// ```
public struct ConsumedField: Codable, Sendable, Equatable {
    /// The bare field name (e.g. "tags", "title").
    public let name: String
    /// Optional type hint (e.g. "string", "csv", "bool", "duration").
    public let type: String?
    /// Optional human-readable description.
    public let description: String?
    /// Whether this field is read-only (cannot be targeted by emit/write actions).
    public let readOnly: Bool

    public init(name: String, type: String? = nil, description: String? = nil, readOnly: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.readOnly = readOnly
    }
}
```

- [ ] **Step 2: Build PiqleyCore to see all compile errors**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1 | head -30`
Expected: compile errors in test files where `ConsumedField` is constructed without `readOnly`.

- [ ] **Step 3: Fix PiqleyCore tests**

In `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/`, find all `ConsumedField(` calls and add `readOnly: false` (or `readOnly: true` for test cases that test read-only behavior). Search with: `grep -rn "ConsumedField(" Tests/`

- [ ] **Step 4: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```
feat: add readOnly flag to ConsumedField (breaking change)
```

---

### Task 2: Add `readOnly` to `FieldInfo` (PiqleyCore)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/RuleEditing/FieldInfo.swift`

- [ ] **Step 1: Add `readOnly` property to `FieldInfo`**

Replace the `FieldInfo` struct (keep `FieldCategory` unchanged):

```swift
/// A single metadata field available for use in rule conditions and emit actions.
public struct FieldInfo: Sendable, Equatable {
    /// The bare field name, e.g. "ISO".
    public let name: String
    /// The source namespace that owns this field, e.g. "original", "exif-tagger".
    public let source: String
    /// The fully-qualified name combining source and field name, e.g. "exif-tagger:ISO".
    public let qualifiedName: String
    /// Display/sort category for grouping fields in the rule editor wizard.
    public let category: FieldCategory
    /// Whether this field is read-only (cannot be targeted by emit/write actions).
    public let readOnly: Bool

    /// Full initialiser with explicit qualifiedName.
    public init(name: String, source: String, qualifiedName: String, category: FieldCategory, readOnly: Bool) {
        self.name = name
        self.source = source
        self.qualifiedName = qualifiedName
        self.category = category
        self.readOnly = readOnly
    }

    /// Convenience initialiser that derives `qualifiedName` as `"\(source):\(name)"`.
    public init(name: String, source: String, category: FieldCategory, readOnly: Bool) {
        self.name = name
        self.source = source
        self.qualifiedName = "\(source):\(name)"
        self.category = category
        self.readOnly = readOnly
    }
}
```

- [ ] **Step 2: Build PiqleyCore to see all compile errors**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1 | head -40`
Expected: compile errors in `MetadataFieldCatalog.swift` and test files.

- [ ] **Step 3: Update `MetadataFieldCatalog.fields(forSource:)` to pass `readOnly: true`**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/RuleEditing/MetadataFieldCatalog.swift`, update the `fields(forSource:)` method. Change the `FieldInfo` construction at line 147:

```swift
    public static func fields(forSource source: String) -> [FieldInfo] {
        guard let entry = sourceMap[source] else {
            return []
        }
        return entry.names
            .sorted()
            .map { name in
                FieldInfo(
                    name: name,
                    source: source,
                    qualifiedName: "\(entry.prefix):\(name)",
                    category: entry.category,
                    readOnly: true
                )
            }
    }
```

- [ ] **Step 4: Fix all PiqleyCore test `FieldInfo` constructions**

In `MetadataFieldCatalogTests.swift`, add `readOnly: false` to the two explicit `FieldInfo` inits at lines 115 and 124:

```swift
    @Test("FieldInfo convenience init builds qualifiedName from source and name")
    func fieldInfoQualifiedName() {
        let field = FieldInfo(name: "ISO", source: "exif", category: .exif, readOnly: false)
        #expect(field.qualifiedName == "exif:ISO")
        #expect(field.name == "ISO")
        #expect(field.source == "exif")
        #expect(field.category == .exif)
        #expect(field.readOnly == false)
    }

    @Test("FieldInfo full init uses explicit qualifiedName")
    func fieldInfoFullInit() {
        let field = FieldInfo(name: "ISO", source: "exif", qualifiedName: "EXIF:ISO", category: .exif, readOnly: false)
        #expect(field.qualifiedName == "EXIF:ISO")
        #expect(field.source == "exif")
        #expect(field.category == .exif)
        #expect(field.readOnly == false)
    }

    @Test("FieldInfo for plugin source has custom category")
    func fieldInfoPluginSource() {
        let field = FieldInfo(name: "MyField", source: "exif-tagger", category: .custom, readOnly: false)
        #expect(field.category == .custom)
        #expect(field.source == "exif-tagger")
        #expect(field.qualifiedName == "exif-tagger:MyField")
        #expect(field.readOnly == false)
    }
```

In `RuleEditingContextTests.swift`, add `readOnly: false` to all `FieldInfo` inits in `makeContext()` (lines 24-28) and in `fieldsInKnownSourceReturnsSortedByCategoryThenName` (lines 91-95):

```swift
    private func makeContext() -> RuleEditingContext {
        let fields: [String: [FieldInfo]] = [
            "exif": [
                FieldInfo(name: "ISO", source: "exif", category: .exif, readOnly: false),
                FieldInfo(name: "Aperture", source: "exif", category: .exif, readOnly: false),
            ],
            "iptc": [
                FieldInfo(name: "Keywords", source: "iptc", category: .iptc, readOnly: false),
            ],
            "custom": [
                FieldInfo(name: "Rating", source: "custom", category: .custom, readOnly: false),
            ],
        ]
        // ... rest unchanged
    }
```

```swift
    @Test func fieldsInKnownSourceReturnsSortedByCategoryThenName() {
        let fields: [String: [FieldInfo]] = [
            "mixed": [
                FieldInfo(name: "Zebra", source: "exif", category: .exif, readOnly: false),
                FieldInfo(name: "Alpha", source: "iptc", category: .iptc, readOnly: false),
                FieldInfo(name: "Middle", source: "exif", category: .exif, readOnly: false),
            ]
        ]
        // ... rest unchanged
    }
```

- [ ] **Step 5: Add test for catalog fields being readOnly**

Add to `MetadataFieldCatalogTests.swift`:

```swift
    @Test("catalog fields are readOnly")
    func catalogFieldsAreReadOnly() {
        for source in ["exif", "iptc", "xmp", "tiff"] {
            let fields = MetadataFieldCatalog.fields(forSource: source)
            for field in fields {
                #expect(field.readOnly == true, "Expected \(source):\(field.name) to be readOnly")
            }
        }
    }
```

- [ ] **Step 6: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```
feat: add readOnly flag to FieldInfo and mark catalog fields read-only
```

---

### Task 3: Rename `consumedFields` to `fields` in `PluginManifest` (PiqleyCore)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`

- [ ] **Step 1: Rename property, init parameter, and CodingKey**

In `PluginManifest.swift`:

1. Line 26: rename `consumedFields` to `fields`
2. Line 44: rename init parameter `consumedFields` to `fields`
3. Line 58: rename assignment `self.consumedFields` to `self.fields`
4. Line 66: rename CodingKey `case consumedFields` to `case fields`
5. Line 90: rename `consumedFields = ...` to `fields = ...` and change `.consumedFields` to `.fields`
6. Lines 107-108: rename `consumedFields` to `fields` and `.consumedFields` to `.fields`

- [ ] **Step 2: Build PiqleyCore to verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1 | head -20`
Expected: clean build (no tests reference `consumedFields` directly on manifest).

- [ ] **Step 3: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```
refactor: rename PluginManifest.consumedFields to fields (breaking)
```

---

### Task 4: Rename SDK types and add `Outputs` (PiqleyPluginSDK)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConsumedFieldRegistryBuilder.swift`

- [ ] **Step 1: Rewrite the file with renames and `Outputs` struct**

Replace entire file:

```swift
import Foundation
import PiqleyCore

// MARK: - FieldRegistry

/// A registry of fields built with a result builder DSL.
///
/// Plugin authors declare the state fields their plugin works with:
/// ```swift
/// public let pluginFields = FieldRegistry {
///     Consumes(.title, type: "string", description: "Post title")
///     Outputs(.day_diff, type: "int", description: "Days difference")
/// }
/// ```
public struct FieldRegistry: Sendable {
    public let fields: [ConsumedField]

    public init(@FieldBuilder _ builder: () -> [ConsumedField]) {
        self.fields = builder()
    }

    /// Writes the registry's fields to `fields.json` in the given directory.
    public func writeFields(to directory: URL) throws {
        let data = try JSONEncoder.piqleyPrettyPrint.encode(fields)
        try data.write(
            to: directory.appendingPathComponent("fields.json"),
            options: .atomic
        )
    }
}

// MARK: - Consumes

/// A consumed (writable) field declaration for use in `FieldRegistry`.
public struct Consumes: Sendable {
    let fields: [ConsumedField]

    /// Declare a single consumed field from a `StateKey` case with optional metadata.
    public init<K: StateKey>(_ key: K, type: String? = nil, description: String? = nil) {
        self.fields = [ConsumedField(name: key.rawValue, type: type, description: description, readOnly: false)]
    }

    /// Bulk-declare all cases of a `StateKey & CaseIterable` enum.
    public init<K: StateKey & CaseIterable>(_ type: K.Type) {
        self.fields = K.allCases.map { ConsumedField(name: $0.rawValue, readOnly: false) }
    }

    /// Declare a consumed field by raw name with optional metadata.
    public init(_ name: String, type: String? = nil, description: String? = nil) {
        self.fields = [ConsumedField(name: name, type: type, description: description, readOnly: false)]
    }
}

// MARK: - Outputs

/// A read-only output field declaration for use in `FieldRegistry`.
///
/// Output fields are visible in match conditions but cannot be targeted
/// by emit or write actions in the rules editor.
public struct Outputs: Sendable {
    let fields: [ConsumedField]

    /// Declare a single output field from a `StateKey` case with optional metadata.
    public init<K: StateKey>(_ key: K, type: String? = nil, description: String? = nil) {
        self.fields = [ConsumedField(name: key.rawValue, type: type, description: description, readOnly: true)]
    }

    /// Bulk-declare all cases of a `StateKey & CaseIterable` enum as read-only output fields.
    public init<K: StateKey & CaseIterable>(_ type: K.Type) {
        self.fields = K.allCases.map { ConsumedField(name: $0.rawValue, readOnly: true) }
    }

    /// Declare an output field by raw name with optional metadata.
    public init(_ name: String, type: String? = nil, description: String? = nil) {
        self.fields = [ConsumedField(name: name, type: type, description: description, readOnly: true)]
    }
}

// MARK: - FieldBuilder

@resultBuilder
public enum FieldBuilder {
    public static func buildBlock(_ components: [ConsumedField]...) -> [ConsumedField] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: Consumes) -> [ConsumedField] {
        expression.fields
    }

    public static func buildExpression(_ expression: Outputs) -> [ConsumedField] {
        expression.fields
    }
}
```

- [ ] **Step 2: Build PiqleyPluginSDK to see compile errors**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift build 2>&1 | head -30`
Expected: errors in `Packager.swift` and `BuildManifest.swift` referencing old names.

- [ ] **Step 3: Commit**

```
feat: rename to FieldRegistry/FieldBuilder, add Outputs struct (breaking)
```

---

### Task 5: Update `Packager` and `BuildManifest` (PiqleyPluginSDK)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Packager.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/BuildManifest.swift`

- [ ] **Step 1: Update `Packager.swift`**

Change line 30 comment: `consumed-fields.json` to `fields.json`
Change line 40: `"consumed-fields.json"` to `"fields.json"`
Change line 41: `consumedFieldsOverride` to `fieldsOverride`
Change line 44: `consumedFieldsOverride` to `fieldsOverride`
Change line 46: `consumedFieldsOverride` to `fieldsOverride`
Change line 51: `consumedFieldsOverride` to `fieldsOverride`

The relevant section becomes:

```swift
        // 2. Load config-entries.json and fields.json if they exist
        let configEntriesURL = directory.appendingPathComponent("config-entries.json")
        let configOverride: [ConfigEntry]?
        if fm.fileExists(atPath: configEntriesURL.path) {
            let configData = try Data(contentsOf: configEntriesURL)
            configOverride = try JSONDecoder.piqley.decode([ConfigEntry].self, from: configData)
        } else {
            configOverride = nil
        }

        let fieldsURL = directory.appendingPathComponent("fields.json")
        let fieldsOverride: [ConsumedField]?
        if fm.fileExists(atPath: fieldsURL.path) {
            let fieldsData = try Data(contentsOf: fieldsURL)
            fieldsOverride = try JSONDecoder.piqley.decode([ConsumedField].self, from: fieldsData)
        } else {
            fieldsOverride = nil
        }

        let pluginManifest = try buildManifest.toPluginManifest(
            configOverride: configOverride,
            fieldsOverride: fieldsOverride
        )
```

- [ ] **Step 2: Update `BuildManifest.swift`**

Change the `toPluginManifest` method (lines 63-83):

```swift
    public func toPluginManifest(
        configOverride: [ConfigEntry]? = nil,
        fieldsOverride: [ConsumedField]? = nil
    ) throws -> PluginManifest {
        let semver: SemanticVersion? = try pluginVersion.map { try SemanticVersion($0) }
        return PluginManifest(
            identifier: identifier,
            name: pluginName,
            type: .static,
            description: description,
            pluginSchemaVersion: pluginSchemaVersion,
            pluginVersion: semver,
            config: configOverride ?? config ?? [],
            setup: setup,
            dependencies: dependencies,
            supportedFormats: supportedFormats,
            conversionFormat: conversionFormat,
            supportedPlatforms: Array(bin.keys).sorted(),
            fields: fieldsOverride ?? []
        )
    }
```

- [ ] **Step 3: Build PiqleyPluginSDK**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift build 2>&1 | tail -20`
Expected: clean build.

- [ ] **Step 4: Commit**

```
refactor: rename consumed-fields.json to fields.json in Packager and BuildManifest
```

---

### Task 6: Update `FieldDiscovery` to propagate `readOnly` (piqley-cli)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/FieldDiscovery.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/FieldDiscoveryTests.swift`

- [ ] **Step 1: Update `DependencyInfo` to carry `readOnly` per field**

Replace `DependencyInfo` and related code. The struct needs to carry readOnly info per field. Change it to use `ConsumedField` directly:

```swift
    struct DependencyInfo {
        /// The plugin's unique identifier, used as the dictionary key.
        let identifier: String
        /// The fields exposed by this plugin (with readOnly metadata).
        let fields: [ConsumedField]
    }
```

- [ ] **Step 2: Update `buildAvailableFields` to propagate `readOnly`**

Update `catalogFields(forSource:)` to pass `readOnly: true`:

```swift
    private static func catalogFields(forSource sourceName: String) -> [FieldInfo] {
        ["exif", "iptc", "xmp", "tiff"].flatMap { catalogSource in
            MetadataFieldCatalog.fields(forSource: catalogSource).map { field in
                FieldInfo(
                    name: field.qualifiedName,
                    source: sourceName,
                    qualifiedName: "\(sourceName):\(field.qualifiedName)",
                    category: field.category,
                    readOnly: true
                )
            }
        }.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            return lhs.name < rhs.name
        }
    }
```

Update `buildAvailableFields` dependency loop to propagate `readOnly`:

```swift
    static func buildAvailableFields(dependencies: [DependencyInfo]) -> [String: [FieldInfo]] {
        var result: [String: [FieldInfo]] = [:]
        result["original"] = catalogFields(forSource: "original")
        result["read"] = catalogFields(forSource: "read")

        for dep in dependencies {
            result[dep.identifier] = dep.fields.sorted(by: { $0.name < $1.name }).map { field in
                FieldInfo(name: field.name, source: dep.identifier, category: .custom, readOnly: field.readOnly)
            }
        }

        return result
    }
```

- [ ] **Step 3: Update `discoverUpstreamFields` to use `ConsumedField` in `DependencyInfo`**

In `discoverUpstreamFields`, change the fields set to track readOnly. Fields discovered from rules emit actions are writable (`readOnly: false`). Fields from manifest are preserved as-is:

```swift
        // 3. Harvest fields from each upstream plugin's rules files and manifest fields
        var result: [DependencyInfo] = []
        for entry in upstreamStages {
            var fieldsByName: [String: ConsumedField] = [:]

            // Scan rules files for emitted fields (writable)
            for stage in entry.stages {
                let filename = "\(PluginFile.stagePrefix)\(stage)\(PluginFile.stageSuffix)"
                let fileURL = rulesBaseDir
                    .appendingPathComponent(entry.identifier)
                    .appendingPathComponent(filename)

                guard let data = try? Data(contentsOf: fileURL),
                      let stageConfig = try? JSONDecoder.piqley.decode(StageConfig.self, from: data)
                else { continue }

                let allRules = (stageConfig.preRules ?? []) + (stageConfig.postRules ?? [])
                for rule in allRules {
                    for emit in rule.emit {
                        if let field = emit.field, field != "*" {
                            fieldsByName[field] = ConsumedField(name: field, readOnly: false)
                        }
                    }
                }
            }

            // Merge manifest fields (preserves readOnly from manifest)
            let manifestURL = pluginsDir
                .appendingPathComponent(entry.identifier)
                .appendingPathComponent(PluginFile.manifest)
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder.piqley.decode(PluginManifest.self, from: data)
            {
                for field in manifest.fields {
                    // Manifest declaration takes precedence over rules discovery
                    fieldsByName[field.name] = field
                }
            }

            if !fieldsByName.isEmpty {
                result.append(DependencyInfo(
                    identifier: entry.identifier,
                    fields: Array(fieldsByName.values)
                ))
            }
        }

        return result
```

- [ ] **Step 4: Update test file to use new `DependencyInfo` API**

In `FieldDiscoveryTests.swift`, update all `DependencyInfo` constructions to use `[ConsumedField]` instead of `[String]`:

```swift
    @Test("dependency plugin fields appear under plugin identifier key")
    func dependencyFieldsKeyedByIdentifier() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "com.example.myplugin",
            fields: [
                ConsumedField(name: "AlbumName", readOnly: false),
                ConsumedField(name: "CameraSerial", readOnly: false),
            ]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let depFields = result["com.example.myplugin"]
        #expect(depFields != nil)
        #expect(depFields?.count == 2)
    }

    @Test("dependency fields have custom category")
    func dependencyFieldsAreCustomCategory() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "exif-tagger",
            fields: [ConsumedField(name: "scene", readOnly: false)]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let field = result["exif-tagger"]?.first
        #expect(field?.category == .custom)
        #expect(field?.source == "exif-tagger")
    }

    @Test("dependency fields are sorted alphabetically")
    func dependencyFieldsSortedAlphabetically() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "com.example.plugin",
            fields: [
                ConsumedField(name: "Zebra", readOnly: false),
                ConsumedField(name: "Alpha", readOnly: false),
                ConsumedField(name: "Middle", readOnly: false),
            ]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let names = result["com.example.plugin"]?.map(\.name) ?? []
        #expect(names == ["Alpha", "Middle", "Zebra"])
    }

    @Test("multiple dependencies each get their own key")
    func multipleDependenciesEachGetOwnKey() {
        let dep1 = FieldDiscovery.DependencyInfo(
            identifier: "plugin.a",
            fields: [ConsumedField(name: "FieldA", readOnly: false)]
        )
        let dep2 = FieldDiscovery.DependencyInfo(
            identifier: "plugin.b",
            fields: [ConsumedField(name: "FieldB", readOnly: false)]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep1, dep2])
        #expect(result["plugin.a"] != nil)
        #expect(result["plugin.b"] != nil)
    }
```

Also add a test for readOnly propagation:

```swift
    @Test("readOnly flag propagates from DependencyInfo to FieldInfo")
    func readOnlyPropagates() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "plugin.test",
            fields: [
                ConsumedField(name: "writable", readOnly: false),
                ConsumedField(name: "computed", readOnly: true),
            ]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let fields = result["plugin.test"] ?? []
        let writable = fields.first { $0.name == "writable" }
        let computed = fields.first { $0.name == "computed" }
        #expect(writable?.readOnly == false)
        #expect(computed?.readOnly == true)
    }

    @Test("original and read fields are all readOnly")
    func originalAndReadFieldsAreReadOnly() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        for source in ["original", "read"] {
            let fields = result[source] ?? []
            for field in fields {
                #expect(field.readOnly == true, "Expected \(source):\(field.name) to be readOnly")
            }
        }
    }
```

- [ ] **Step 5: Run piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter FieldDiscovery 2>&1 | tail -20`
Expected: all FieldDiscovery tests pass.

- [ ] **Step 6: Commit**

```
feat: propagate readOnly through FieldDiscovery
```

---

### Task 7: Update CLI commands to use `manifest.fields` (piqley-cli)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/WorkflowRulesCommand.swift:79-81`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/WorkflowCommandEditCommand.swift:83-85`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/ConfigWizard+Rules.swift:47-49`

- [ ] **Step 1: Update `WorkflowRulesCommand.swift`**

Change lines 79-81 from:
```swift
            if !manifest.consumedFields.isEmpty {
                let ownFields = manifest.consumedFields.map(\.name)
                allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: ownFields))
```
To:
```swift
            if !manifest.fields.isEmpty {
                allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: manifest.fields))
```

- [ ] **Step 2: Update `WorkflowCommandEditCommand.swift`**

Change lines 83-85 from:
```swift
            if !manifest.consumedFields.isEmpty {
                let ownFields = manifest.consumedFields.map(\.name)
                allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: ownFields))
```
To:
```swift
            if !manifest.fields.isEmpty {
                allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: manifest.fields))
```

- [ ] **Step 3: Update `ConfigWizard+Rules.swift`**

Change lines 47-49 from:
```swift
        if !plugin.manifest.consumedFields.isEmpty {
            let ownFields = plugin.manifest.consumedFields.map(\.name)
            allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: ownFields))
```
To:
```swift
        if !plugin.manifest.fields.isEmpty {
            allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: plugin.manifest.fields))
```

- [ ] **Step 4: Build piqley-cli**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -20`
Expected: clean build.

- [ ] **Step 5: Commit**

```
refactor: update CLI to use manifest.fields instead of consumedFields
```

---

### Task 8: Filter read-only fields in rules editor (piqley-cli)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard+FieldSelection.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard+BuildRule.swift`

- [ ] **Step 1: Add `buildWritableFieldCompletions()` method to `RulesWizard+FieldSelection.swift`**

Add this method after `buildFieldCompletions()`:

```swift
    /// Builds field completions excluding read-only fields, for use in emit/write target prompts.
    /// Returns the filtered completions and a count of how many read-only fields were excluded.
    func buildWritableFieldCompletions() -> (completions: [String], readOnlyCount: Int) {
        var ownFields = Set<String>()
        var otherFields = Set<String>()
        var readOnlyCount = 0
        let pluginID = context.pluginIdentifier
        for source in context.availableSources() {
            for field in context.fields(in: source) {
                if field.readOnly {
                    readOnlyCount += 1
                    continue
                }
                if source == pluginID {
                    ownFields.insert(field.name)
                } else {
                    otherFields.insert(field.qualifiedName)
                }
            }
        }
        for stageName in context.stageNames() {
            for slot in [RuleSlot.pre, .post] {
                for rule in context.rules(forStage: stageName, slot: slot) {
                    for emit in rule.emit {
                        if let field = emit.field { ownFields.insert(field) }
                    }
                    for write in rule.write {
                        if let field = write.field { ownFields.insert(field) }
                    }
                }
            }
        }
        otherFields.subtract(ownFields)
        return (completions: ownFields.sorted() + otherFields.sorted(), readOnlyCount: readOnlyCount)
    }
```

- [ ] **Step 2: Update `promptForEmitConfig` to use writable completions and show hint**

In `RulesWizard+BuildRule.swift`, change `promptForEmitConfig` (line 148-166) to use the new method:

```swift
    func promptForEmitConfig(action: String) -> EmitConfig? {
        let (uniqueFields, readOnlyCount) = buildWritableFieldCompletions()

        if readOnlyCount > 0 {
            terminal.showMessage("\(ANSI.dim)\(readOnlyCount) read-only field\(readOnlyCount == 1 ? "" : "s") not shown\(ANSI.reset)")
        }

        var field: String
        while true {
            let verb = actionFieldVerb(action)
            guard let input = terminal.promptWithAutocomplete(
                title: "Target field for \(action)",
                hint: "The field to \(verb) (e.g. keywords, original:IPTC:Keywords)",
                completions: uniqueFields,
                browsableList: uniqueFields,
                noMatchHint: "Enter will create a new field with this name"
            ) else { return nil }

            if uniqueFields.contains(input) || terminal.confirm("'\(input)' is a new field name. Use it anyway?") {
                field = input
                break
            }
        }
        // ... rest of switch unchanged
```

- [ ] **Step 3: Build piqley-cli**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -20`
Expected: clean build.

- [ ] **Step 4: Run all piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```
feat: filter read-only fields from emit/write targets, show hint in TUI
```

---

### Task 9: Update plugins to use `FieldRegistry` and `Outputs`

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/plugins/photo.quigs.datetools/Sources/PluginHooks/Hooks.swift`
- Modify: `/Users/wash/Developer/tools/piqley/plugins/photo.quigs.resize/Sources/PluginHooks/Hooks.swift`
- Modify: `/Users/wash/Developer/tools/piqley/plugins/photo.quigs.ghostcms.publisher/Sources/PluginHooks/Hooks.swift`

- [ ] **Step 1: Update datetools plugin**

Replace lines 10-20:

```swift
public let pluginFields = FieldRegistry {
    Consumes("start_date", type: "string", description: "The starting date for difference calculation")
    Consumes("end_date", type: "string", description: "The ending date for difference calculation")
    Consumes("diff_offset", type: "int", description: "Offset to add to all computed differences (1-based counting)")
    Consumes("locale", type: "string", description: "Locale identifier for date parsing (e.g. en_US)")
    Outputs("hour_diff", type: "int", description: "Hours difference between dates")
    Outputs("day_diff", type: "int", description: "Days difference between dates")
    Outputs("week_diff", type: "int", description: "Weeks difference between dates")
    Outputs("month_diff", type: "int", description: "Months difference between dates")
    Outputs("year_diff", type: "int", description: "Years difference between dates")
}
```

- [ ] **Step 2: Update resize plugin**

Replace lines 28-30:

```swift
public let pluginFields = FieldRegistry {
    Consumes("long_edge_px", type: "string", description: "Override the default long edge size in pixels for matched images")
}
```

- [ ] **Step 3: Update ghostcms.publisher plugin**

Replace lines 8-19:

```swift
public let pluginFields = FieldRegistry {
    Consumes(GhostField.title, type: "string", description: "Post title")
    Consumes(GhostField.body, type: "string", description: "Post body (supports Markdown)")
    Consumes(GhostField.tags, type: "csv", description: "Comma-separated tag names")
    Consumes(GhostField.internalTags, type: "csv", description: "Comma-separated internal tag names")
    Consumes(GhostField.isFeatureImage, type: "bool", description: "Use image as feature image instead of inline")
    Consumes(GhostField.isIgnored, type: "bool", description: "Skip uploading and caching this image")
    Consumes(GhostField.scheduleFilter, type: "string", description: "Ghost filter query for finding last scheduled post")
    Consumes(GhostField.scheduleOffset, type: "duration", description: "Offset between posts (e.g. 1d, 2h, 1w)")
    Consumes(GhostField.scheduleWindow, type: "time-range", description: "Time window for scheduling (e.g. 08:00-10:00)")
    Consumes(GhostField.primaryTag, type: "string", description: "Tag to place first in the tags list")
}
```

- [ ] **Step 4: Check if `pluginConsumedFields` is referenced by the SDK's `BuildManifest` or packaging**

Search for references to `pluginConsumedFields` in the SDK to confirm nothing auto-discovers it by that name. If `BuildManifest.swift` references it, update accordingly.

Run: `grep -rn "pluginConsumedFields" /Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/`

- [ ] **Step 5: Update any SDK references to `pluginConsumedFields`**

If found, rename to `pluginFields`. Check the doc comment in `ConsumedFieldRegistryBuilder.swift` (already updated in Task 4).

- [ ] **Step 6: Commit each plugin separately (or together if they share a repo)**

```
refactor: update plugins to use FieldRegistry and Outputs
```

---

### Task 10: Final build and test across all repos

- [ ] **Step 1: Build and test PiqleyCore**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 2: Build and test PiqleyPluginSDK**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift build 2>&1 | tail -20`
Expected: clean build.

- [ ] **Step 3: Build and test piqley-cli**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 4: Verify plugins build**

Run for each plugin:
```
cd /Users/wash/Developer/tools/piqley/plugins/photo.quigs.datetools && swift build 2>&1 | tail -10
cd /Users/wash/Developer/tools/piqley/plugins/photo.quigs.resize && swift build 2>&1 | tail -10
cd /Users/wash/Developer/tools/piqley/plugins/photo.quigs.ghostcms.publisher && swift build 2>&1 | tail -10
```
Expected: clean builds.

- [ ] **Step 5: Final commit if any fixups needed**
