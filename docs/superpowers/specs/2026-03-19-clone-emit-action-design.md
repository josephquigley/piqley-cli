# Clone Emit Action — Design Spec

## Summary

Add a `clone` emit action that copies field values from a source namespace into the plugin's namespace. This enables rules-only plugins to work with existing metadata (e.g., cloning IPTC keywords from `original` and then filtering with `remove`) without needing a plugin binary.

This is a breaking change to `EmitConfig` — a new `source: String?` property is added with no default value. All call sites across PiqleyCore, PiqleyPluginSDK, and the CLI are updated.

## Motivation

Currently, there is no declarative way to copy values from one namespace to another. A plugin that wants to start with the image's existing IPTC keywords and strip a blocklist must use a binary to perform the copy. The clone action makes this a pure rules operation:

```json
{
  "match": { "field": "original:IPTC:Keywords", "pattern": "glob:*" },
  "emit": [
    { "action": "clone", "field": "keywords", "source": "original:IPTC:Keywords" },
    { "action": "remove", "field": "keywords", "values": [
      "regex:.*\\d+mm(\\s+f/[\\d.]+)?.*",
      "regex:^\\d+$",
      "Developer",
      "glob:Chem*"
    ]}
  ]
}
```

## JSON Wire Format

### Single-field clone

Copies one field from a source namespace into the plugin namespace, overwriting any existing value.

```json
{ "action": "clone", "field": "keywords", "source": "original:IPTC:Keywords" }
```

- `field`: target field name in the plugin namespace.
- `source`: `"namespace:field"` reference, parsed by splitting on first colon (same as match-side field resolution).
- The target field is overwritten entirely — no merging or deduplication.
- If the source field does not exist, the action is a no-op.

### Wildcard clone

Copies all fields from a source namespace into the plugin namespace.

```json
{ "action": "clone", "field": "*", "source": "original" }
```

- `field`: must be `"*"`.
- `source`: namespace name only (no colon/field part).
- Each source field overwrites the corresponding target field.
- Existing plugin fields not present in the source are preserved.
- If the source namespace does not exist, the action is a no-op.

### `read:` namespace support

Clone resolves `read:` sources through `MetadataBuffer`, same as match-side `read:` resolution.

```json
{ "action": "clone", "field": "keywords", "source": "read:IPTC:Keywords" }
```

### Field summary

| Action | `field` | `values` | `replacements` | `source` |
|--------|---------|----------|----------------|----------|
| add (default) | required | values to add | — | — |
| remove | required | values/patterns to remove | — | — |
| replace | required | — | ordered pattern → replacement mappings | — |
| removeField | required (or `"*"`) | — | — | — |
| clone | required (or `"*"`) | — | — | required (`"namespace:field"` or `"namespace"` for wildcard) |

## PiqleyCore Changes

### EmitConfig

Add `source: String?` with no default value. All parameters are explicit.

```swift
public struct EmitConfig: Codable, Sendable, Equatable {
    public let action: String?
    public let field: String
    public let values: [String]?
    public let replacements: [Replacement]?
    public let source: String?

    public init(action: String?, field: String, values: [String]?, replacements: [Replacement]?, source: String?) {
        self.action = action
        self.field = field
        self.values = values
        self.replacements = replacements
        self.source = source
    }
}
```

All existing call sites must be updated to pass `source:` explicitly.

## CLI Changes

### EmitAction

New enum case:

```swift
enum EmitAction: Sendable {
    case add(field: String, values: [String])
    case remove(field: String, matchers: [any TagMatcher & Sendable])
    case replace(field: String, replacements: [(matcher: any TagMatcher & Sendable, replacement: String)])
    case removeField(field: String)
    case clone(field: String, sourceNamespace: String, sourceField: String?)
}
```

`sourceField` is nil when `field` is `"*"` (wildcard clone).

### RuleEvaluator — Compilation

`compileEmitAction` adds a `"clone"` case:

- `source` must be non-nil and non-empty.
- `values` must be nil.
- `replacements` must be nil.
- Source is parsed via `splitField` into namespace and field components.
- When `field` is `"*"`, `sourceField` is nil (the entire source string is treated as the namespace name).

All other actions validate that `source` is nil.

### RuleEvaluator — Evaluation

Clone is handled inline in `evaluate` (not in `applyAction`) because it needs access to the full `state` map and optionally `MetadataBuffer`. The static `applyAction(_:to:)` method remains unchanged for the other four actions.

```swift
case let .clone(field, sourceNamespace, sourceField):
    if sourceNamespace == "read", let buffer = metadataBuffer, let image = imageName {
        let fileMetadata = await buffer.load(image: image)
        if field == "*" {
            for (key, value) in fileMetadata {
                working[key] = value
            }
        } else if let sourceField, let value = fileMetadata[sourceField] {
            working[field] = value
        }
    } else if field == "*" {
        if let namespaceData = state[sourceNamespace] {
            for (key, value) in namespaceData {
                working[key] = value
            }
        }
    } else if let sourceField, let value = state[sourceNamespace]?[sourceField] {
        working[field] = value
    }
```

## PiqleyPluginSDK Changes

### RuleEmit

Add clone cases:

```swift
public enum RuleEmit: Sendable {
    // existing cases...
    case clone(field: String, source: String)
    case cloneKeywords(source: String)
    case cloneAll(source: String)
}
```

Mapping:

| Case | `action` | `field` | `source` |
|------|----------|---------|----------|
| `clone(f, s)` | `"clone"` | `f` | `s` |
| `cloneKeywords(s)` | `"clone"` | `"keywords"` | `s` |
| `cloneAll(s)` | `"clone"` | `"*"` | `s` |

`toEmitConfig()` additions:

```swift
case let .clone(field, source):
    EmitConfig(action: "clone", field: field, values: nil, replacements: nil, source: source)
case let .cloneKeywords(source):
    EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: source)
case let .cloneAll(source):
    EmitConfig(action: "clone", field: "*", values: nil, replacements: nil, source: source)
```

### Builder DSL example

```swift
ConfigRule(
    match: .field(.original(.iptcKeywords), pattern: .glob("*")),
    emit: [
        .cloneKeywords(source: "original:IPTC:Keywords"),
        .removeKeywords([
            "regex:.*\\d+mm(\\s+f/[\\d.]+)?.*",
            "regex:^\\d+$",
            "Developer",
            "glob:Chem*"
        ])
    ]
)
```

## Validation

| Constraint | Behavior |
|---|---|
| `clone`: `source` must be non-empty | Error |
| `clone`: `values` must be absent | Error |
| `clone`: `replacements` must be absent | Error |
| `add`, `remove`, `replace`, `removeField`: `source` must be absent | Error |

In non-interactive mode, invalid rules are skipped with a warning logged.

## Scope

### In scope
- `EmitConfig.source` property (breaking change, no defaults)
- `EmitAction.clone` case in CLI
- Clone handling in `RuleEvaluator.evaluate`
- Compile-time validation for clone
- Cross-validation: existing actions reject non-nil `source`
- SDK `RuleEmit` clone cases and `toEmitConfig()` mapping
- Update all existing call sites and test fixtures for the breaking `EmitConfig` change

### Out of scope
- Clone in `write` actions (clone targets the plugin namespace, not file metadata)
