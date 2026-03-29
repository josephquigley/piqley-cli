# Read-Only Output Fields

## Problem

Plugins like `photo.quigs.datetools` write computed values (e.g. `day_diff`, `month_diff`) to their namespace fields. The rules editor currently allows users to target these fields with emit/write actions (add, replace, remove, etc.), which makes no sense for computed output. Similarly, the "original" and "read" namespaces contain source image metadata that should not be writable through the rules editor.

## Solution

Add a `readOnly: Bool` flag to `ConsumedField` and `FieldInfo`. Read-only fields remain available for match conditions but are filtered out of emit/write action target autocomplete. A TUI hint shows how many read-only fields were hidden.

## Breaking Changes

This design intentionally breaks backwards compatibility:
- `ConsumedField.init` requires the `readOnly` parameter (no default).
- `FieldInfo.init` requires the `readOnly` parameter (no default).
- `consumed-fields.json` renamed to `fields.json`.
- `ConsumedFieldRegistry` renamed to `FieldRegistry`.
- `ConsumedFieldBuilder` renamed to `FieldBuilder`.
- `PluginManifest.consumedFields` renamed to `PluginManifest.fields` (JSON key: `"fields"`).

## Data Model

### PiqleyCore: `ConsumedField`

```swift
public struct ConsumedField: Codable, Sendable, Equatable {
    public let name: String
    public let type: String?
    public let description: String?
    public let readOnly: Bool

    public init(name: String, type: String? = nil, description: String? = nil, readOnly: Bool) {
        // ...
    }
}
```

JSON:
```json
{ "name": "day_diff", "type": "int", "description": "Days difference", "readOnly": true }
```

### PiqleyCore: `FieldInfo`

```swift
public struct FieldInfo: Sendable, Equatable {
    public let name: String
    public let source: String
    public let qualifiedName: String
    public let category: FieldCategory
    public let readOnly: Bool
}
```

Both initializers gain the `readOnly: Bool` parameter.

### PiqleyCore: `PluginManifest`

- Property renamed: `consumedFields` to `fields`.
- CodingKey renamed: `"consumedFields"` to `"fields"`.
- Init parameter renamed accordingly.

### PiqleyCore: `MetadataFieldCatalog`

All fields in the "original" and "read" sources are constructed with `readOnly: true`.

## Plugin SDK

### Rename `ConsumedFieldRegistryBuilder.swift`

- `ConsumedFieldRegistry` becomes `FieldRegistry`.
- `ConsumedFieldBuilder` becomes `FieldBuilder`.
- The `writeConsumedFields(to:)` method becomes `writeFields(to:)` and writes to `fields.json`.

### `Consumes` struct

Updated to pass `readOnly: false` in all initializers. Internal property renamed from `consumed` to `fields`.

### New `Outputs` struct

```swift
public struct Outputs: Sendable {
    let fields: [ConsumedField]

    public init<K: StateKey>(_ key: K, type: String? = nil, description: String? = nil) {
        self.fields = [ConsumedField(name: key.rawValue, type: type, description: description, readOnly: true)]
    }

    public init<K: StateKey & CaseIterable>(_ type: K.Type) {
        self.fields = K.allCases.map { ConsumedField(name: $0.rawValue, readOnly: true) }
    }

    public init(_ name: String, type: String? = nil, description: String? = nil) {
        self.fields = [ConsumedField(name: name, type: type, description: description, readOnly: true)]
    }
}
```

### `FieldBuilder`

Gains a `buildExpression(_ expression: Outputs)` overload. Both `Consumes` and `Outputs` share the same `fields: [ConsumedField]` property, so the builder flattens them identically in `buildBlock`:

```swift
FieldRegistry {
    Consumes(.start_date, type: "string", description: "Starting date")
    Outputs(.day_diff, type: "int", description: "Days difference")
}
```

### `Packager` and `BuildManifest`

- `Packager` reads `fields.json` instead of `consumed-fields.json`.
- `BuildManifest.toPluginManifest` parameter renamed from `consumedFieldsOverride` to `fieldsOverride`.

## CLI: Rules Editor

### Emit/write target field filtering

When building field completions for `promptForEmitConfig`, filter out any `FieldInfo` where `readOnly == true`.

### Source namespace filtering for emit targets

When selecting a source namespace for an emit action target, hide namespaces where all fields are read-only (zero writable fields available).

### TUI hint

After presenting the filtered field list, display a dim note when read-only fields were hidden:

```
3 read-only fields not shown
```

Uses `ANSI.dim` styling. Only shown when the count is greater than zero.

### Match conditions

No filtering. Read-only fields remain fully available.

### CLI sites that reference `consumedFields`

These files reference `manifest.consumedFields` and must be updated to `manifest.fields`:
- `Sources/piqley/CLI/WorkflowRulesCommand.swift`
- `Sources/piqley/CLI/WorkflowCommandEditCommand.swift`
- `Sources/piqley/Wizard/ConfigWizard+Rules.swift`
- `Sources/piqley/Wizard/FieldDiscovery.swift`

## Affected Repos

1. **piqley-core**: `ConsumedField`, `FieldInfo`, `PluginManifest`, `MetadataFieldCatalog`
2. **piqley-plugin-sdk**: `ConsumedFieldRegistryBuilder.swift` (rename file), `Packager.swift`, `BuildManifest.swift`
3. **piqley-cli**: `FieldDiscovery.swift`, `RulesWizard+FieldSelection.swift`, `RulesWizard+BuildRule.swift`, `WorkflowRulesCommand.swift`, `WorkflowCommandEditCommand.swift`, `ConfigWizard+Rules.swift`
4. **Plugins** (photo.quigs.datetools, photo.quigs.resize, photo.quigs.ghostcms.publisher): Update `pluginConsumedFields` references to use `FieldRegistry` and `Outputs` where appropriate.
