# Consumed Fields: Manifest-Declared State Fields

## Problem

Plugins that read state fields (e.g., the Ghost CMS publisher reading `tags`, `title`, `schedule_offset`) have no way to declare those fields in their manifest. The rules editor discovers fields by scanning upstream plugins' rules files for emit configs, but if no rules exist yet, there's nothing to discover. Users must remember exact field names when writing rules.

## Solution

Add a `consumedFields` array to `PluginManifest` that declares the state fields a plugin works with. These fields are surfaced in:

1. The plugin's own rules editor (so you can write `self:tags` rules without guessing)
2. Downstream plugins' rules editors (as upstream fields, even before any rules exist)

## Changes by Repo

### PiqleyCore

**New `ConsumedField` struct:**

```swift
public struct ConsumedField: Codable, Sendable, Equatable {
    public let name: String
    public let type: String?
    public let description: String?
}
```

**`PluginManifest` changes:**

Add `consumedFields: [ConsumedField]` property (non-optional, defaults to empty array in initializer). Add it to `CodingKeys`, `init(from:)`, and `encode(to:)`. Update all existing call sites that construct a `PluginManifest` to pass the new parameter.

### PiqleyPluginSDK

**New `ConsumedFieldRegistry` DSL:**

```swift
public let pluginConsumedFields = ConsumedFieldRegistry {
    Consumes(GhostField.self)  // auto-extracts all cases as field names
    // or individual fields with metadata:
    Consumes(.title, type: "string", description: "Post title")
    Consumes(.tags, type: "csv", description: "Comma-separated tag names")
}
```

Components:
- `ConsumedFieldRegistry`: holds `[ConsumedField]`, provides `writeConsumedFields(to:)` that writes `consumed-fields.json`
- `Consumes`: accepts a `StateKey`-conforming type (bulk extract all cases) or individual `StateKey` case with optional `type`/`description`
- `ConsumedFieldBuilder`: result builder that collects `Consumes` entries
- `ConsumedFieldComponent`: protocol for builder expressions

**State accessor overloads on `ResolvedState` and `PluginState`:**

Add overloads for `string(_:)`, `int(_:)`, `bool(_:)`, `double(_:)`, `strings(_:)`, `raw(_:)`, and `set(_:to:)` that accept `ConsumedField` as a key (via the `StateKey` enum the field belongs to). Since `ConsumedField` cases are `StateKey` enum cases, the existing `StateKey` overloads already cover this. No new overloads are needed.

### piqley-cli

**`FieldDiscovery.discoverUpstreamFields` enhancement:**

After scanning rules files for emitted fields, also read each upstream plugin's installed manifest and merge its `consumedFields` names into the discovered field set. This ensures fields appear even when no rules reference them yet.

**Plugin's own consumed fields:**

When `PluginRulesCommand.run()` builds the `RuleEditingContext`, it reads the target plugin's manifest `consumedFields` and includes them in `availableFields` under the plugin's own identifier. This makes them available as `self:fieldName` in the rules editor.

**`FieldCategory`:**

Add a `.consumed` case to distinguish consumed fields from `.custom` (emitted) fields in the editor UI. The editor can optionally display type hints and descriptions from `ConsumedField` metadata.

### Packager

**`BuildManifest.toPluginManifest`:**

Add a `consumedFieldsOverride: [ConsumedField]?` parameter. The packager reads `consumed-fields.json` if present (written by ManifestGen via `ConsumedFieldRegistry.writeConsumedFields(to:)`).

### Ghost CMS Publisher Plugin

**Replace `Constants.StateField` with a `StateKey` enum:**

```swift
enum GhostField: String, StateKey {
    static let namespace = "photo.quigs.ghostcms"
    case title, body, tags
    case internalTags = "internal_tags"
    case isFeatureImage
    case scheduleFilter = "schedule_filter"
    case scheduleOffset = "schedule_offset"
    case scheduleWindow = "schedule_window"
}
```

**Add `ConsumedFieldRegistry`:**

```swift
public let pluginConsumedFields = ConsumedFieldRegistry {
    Consumes(GhostField.self)
}
```

Or with metadata:

```swift
public let pluginConsumedFields = ConsumedFieldRegistry {
    Consumes(.title, type: "string", description: "Post title")
    Consumes(.body, type: "string", description: "Post body (supports Markdown)")
    Consumes(.tags, type: "csv", description: "Comma-separated tag names")
    Consumes(.internalTags, type: "csv", description: "Comma-separated internal tag names")
    Consumes(.isFeatureImage, type: "bool", description: "Use image as feature image instead of inline")
    Consumes(.scheduleFilter, type: "string", description: "Ghost filter query for finding last scheduled post")
    Consumes(.scheduleOffset, type: "duration", description: "Offset between posts (e.g. 1d, 2h, 1w)")
    Consumes(.scheduleWindow, type: "time-range", description: "Time window for scheduling (e.g. 08:00-10:00)")
}
```

**Update `Plugin.swift`:** Replace `ns.string(Constants.StateField.title)` with `ns.string(GhostField.title)` etc.

**Update ManifestGen:** Call `pluginConsumedFields.writeConsumedFields(to: outputDir)`.

## JSON Wire Format

In `manifest.json`:

```json
{
  "identifier": "photo.quigs.ghostcms.publisher",
  "consumedFields": [
    { "name": "title", "type": "string", "description": "Post title" },
    { "name": "tags", "type": "csv", "description": "Comma-separated tag names" },
    { "name": "scheduleOffset", "type": "duration" }
  ]
}
```

`type` and `description` are omitted from JSON when nil.
