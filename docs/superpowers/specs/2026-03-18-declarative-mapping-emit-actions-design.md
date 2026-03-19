# Declarative Mapping Emit Actions — Design Spec

## Summary

Extend the declarative mapping system to support remove, replace, and removeField operations in addition to the existing add behavior. Changes span PiqleyCore (wire types), PiqleyPluginSDK (builder DSL), and the CLI (rule evaluation).

This is a breaking change to the wire format. There are no existing consumers to migrate.

## Motivation

Currently, `EmitConfig` only adds values. Plugins that build up state during `pre-process` have no declarative way to remove, replace, or clear values during later hooks. These operations currently require a plugin binary, even for simple transformations.

## JSON Wire Format

### Rule structure

`Rule.emit` becomes an array of emit operations. Operations are applied in array order.

```json
{
  "match": { "field": "original:TIFF:Model", "pattern": "regex:.*RF.*" },
  "emit": [
    { "action": "removeField", "field": "keywords" },
    { "action": "add", "field": "keywords", "values": ["RF Mount"] }
  ]
}
```

### Actions

#### add (default when `action` is omitted)

Appends values to a field, deduplicating.

```json
{ "action": "add", "field": "keywords", "values": ["Sony", "Mirrorless"] }
```

#### remove

Removes values from a field that match the given entries. Entries support the existing `glob:` and `regex:` prefixes for pattern-based removal; unqualified entries are exact (case-insensitive) matches.

```json
{ "action": "remove", "field": "keywords", "values": ["generic-camera", "glob:auto-*", "regex:temp_.+"] }
```

#### replace

Replaces values in a field using an ordered array of pattern→replacement mappings. Pattern keys support `glob:` and `regex:` prefixes. Replacement strings support `$1`/`$2` capture group references for regex patterns. Replace patterns are whole-match (consistent with match-side behavior). For each existing value, the first matching replacement wins.

```json
{ "action": "replace", "field": "keywords", "replacements": [
  { "pattern": "SONYA7R5", "replacement": "Sony A7R V" },
  { "pattern": "regex:SONY(.+)", "replacement": "Sony $1" }
]}
```

#### removeField

Deletes an entire field from the plugin's namespace. Use `"*"` to remove all fields.

```json
{ "action": "removeField", "field": "keywords" }
```

```json
{ "action": "removeField", "field": "*" }
```

### Field summary

| Action | `field` | `values` | `replacements` |
|--------|---------|----------|----------------|
| add (default) | required | values to add | — |
| remove | required | values/patterns to remove | — |
| replace | required | — | ordered pattern → replacement mappings |
| removeField | required (or `"*"`) | — | — |

## PiqleyCore Changes

### EmitConfig

```swift
public struct EmitConfig: Codable, Sendable, Equatable {
    /// The action to perform. Nil defaults to "add".
    public let action: String?
    /// The target field. Required. Use "*" with removeField to remove all fields.
    public let field: String
    /// Values to add or patterns to remove. Required for add and remove actions.
    public let values: [String]?
    /// Ordered pattern-to-replacement mappings for the replace action.
    public let replacements: [Replacement]?
}

public struct Replacement: Codable, Sendable, Equatable {
    /// The pattern to match. Supports glob: and regex: prefixes.
    public let pattern: String
    /// The replacement string. Supports $1/$2 capture group references for regex patterns.
    public let replacement: String
}
```

### Rule

`emit` changes from a single `EmitConfig` to an array:

```swift
public struct Rule: Codable, Sendable, Equatable {
    public let match: MatchConfig
    public let emit: [EmitConfig]
}
```

### MatchConfig

No changes.

## CLI Changes

### CompiledRule and EmitAction

```swift
enum EmitAction: Sendable {
    case add(field: String, values: [String])
    case remove(field: String, matchers: [any TagMatcher & Sendable])
    case replace(field: String, replacements: [(matcher: any TagMatcher & Sendable, replacement: String)])
    case removeField(field: String) // "*" means remove all fields
}

struct CompiledRule: Sendable {
    let hook: String
    let namespace: String   // match-side namespace
    let field: String       // match-side field
    let matcher: any TagMatcher & Sendable
    let emitActions: [EmitAction]
}
```

`CompiledRule.namespace` and `CompiledRule.field` are the match-side fields (parsed from `MatchConfig.field`). Each `EmitAction` carries its own target field for the emit side.

### RuleEvaluator

The `evaluate` method signature changes to accept the plugin's current namespace state and return a complete replacement of that namespace:

```swift
func evaluate(
    hook: String,
    state: [String: [String: JSONValue]],
    currentNamespace: [String: JSONValue]
) -> [String: JSONValue]
```

The method starts with a mutable copy of `currentNamespace`. Fields not touched by any emit operation are preserved unchanged. The caller replaces the plugin's namespace in the state store with the returned value.

When `MatchConfig.hook` is nil, the rule defaults to `pre-process`, same as current behavior.

Operation semantics:

- **add**: Appends values, deduplicating by exact string comparison (case-sensitive). Same behavior as today. Note: `remove` uses case-insensitive matching via `TagMatcherFactory`, so add and remove have intentionally different case sensitivity — add preserves casing as-written, remove matches loosely.
- **remove**: Filters out existing values that match any of the matchers built from the `values` entries (using `TagMatcherFactory`, which already handles exact/glob/regex prefixes).
- **replace**: For each existing value in the field, checks each replacement entry's matcher in order. First match wins — the value is replaced using the replacement string. For regex matchers, `$1`/`$2` capture group references are expanded using Swift's `Regex` replacement API.
- **removeField**: If field is `"*"`, empties the entire working dictionary. Otherwise, removes that single field.

Operations within a single rule's `emit` array are applied in order. Rules in the `rules` array are also applied in order.

### Regex replacement

The existing `RegexMatcher` uses Swift's modern `Regex` type. For replace operations, a new method (or a companion type) performs replacement with capture group expansion using `Regex.replacing(_:with:)`.

### Scope constraint

All emit operations target only the current plugin's namespace. The evaluator must not modify state belonging to other plugins or the `original` namespace.

## PiqleyPluginSDK Changes

### RuleEmit

Expands to cover new actions:

```swift
public enum RuleEmit: Sendable {
    case keywords([String])
    case values(field: String, [String])
    case remove(field: String, [String])
    case removeKeywords([String])
    case replace(field: String, [(pattern: String, replacement: String)])
    case replaceKeywords([(pattern: String, replacement: String)])
    case removeField(field: String)
    case removeAllFields
}
```

Each case maps to an `EmitConfig` as follows:

| Case | `action` | `field` | `values` | `replacements` |
|------|----------|---------|----------|----------------|
| `keywords(vs)` | `nil` (add) | `"keywords"` | `vs` | — |
| `values(f, vs)` | `nil` (add) | `f` | `vs` | — |
| `remove(f, vs)` | `"remove"` | `f` | `vs` | — |
| `removeKeywords(vs)` | `"remove"` | `"keywords"` | `vs` | — |
| `replace(f, rs)` | `"replace"` | `f` | — | `rs` mapped to `[Replacement]` |
| `replaceKeywords(rs)` | `"replace"` | `"keywords"` | — | `rs` mapped to `[Replacement]` |
| `removeField(f)` | `"removeField"` | `f` | — | — |
| `removeAllFields` | `"removeField"` | `"*"` | — | — |

### ConfigRule

`emit` becomes an array. The existing `hook` property on `ConfigRule` is removed — hook is already carried by `RuleMatch`. The `toRule()` method maps `[RuleEmit]` to `[EmitConfig]` via `emit.map { $0.toEmitConfig() }`.

```swift
public struct ConfigRule: Sendable {
    let match: RuleMatch
    let emit: [RuleEmit]

    public init(match: RuleMatch, emit: [RuleEmit]) {
        self.match = match
        self.emit = emit
    }
}
```

### Builder DSL example

```swift
ConfigRule(
    match: .field(.original(.model), pattern: .regex(".*RF.*"), hook: .preProcess),
    emit: [
        .removeField(field: "keywords"),
        .values(field: "keywords", ["RF Mount"])
    ]
)

ConfigRule(
    match: .field(.original(.model), pattern: .regex(".*SONY.*")),
    emit: [
        .replaceKeywords([
            (pattern: "regex:SONY(.+)", replacement: "Sony $1")
        ])
    ]
)

ConfigRule(
    match: .field(.original(.model), pattern: .exact("Canon EOS R5")),
    emit: [
        .removeKeywords(["generic-camera", "glob:auto-*"])
    ]
)
```

## Validation

Rules are validated at compile time (in `RuleEvaluator.init`):

| Constraint | Behavior |
|---|---|
| `field` must be non-empty for all actions | Error |
| `add`: `values` must be non-empty | Error |
| `add`: `replacements` must be absent | Error |
| `remove`: `values` must be non-empty | Error |
| `remove`: `replacements` must be absent | Error |
| `replace`: `replacements` must be non-empty | Error |
| `replace`: `values` must be absent | Error |
| `replace`: regex patterns in replacement entries are validated | Error on invalid regex |
| `removeField`: `values` and `replacements` must be absent | Error |
| Unknown action string | Error |

In non-interactive mode, invalid rules are skipped with a warning logged — same pattern as existing rule validation.

## Error Handling

The existing `RuleCompilationError` enum is extended with a new case for invalid emit configurations:

```swift
case invalidEmit(ruleIndex: Int, reason: String)
```

## Future: Read/Write Metadata Actions

Two additional actions are planned but out of scope for this spec:

### write

Writes a value from the plugin's namespace into the image file's metadata. This enables declarative metadata tagging without a plugin binary.

```json
{ "action": "write", "field": "keywords", "target": "IPTC:Keywords" }
```

### read

Reads a metadata field from the image file back into the plugin's namespace. This enables plugins to observe changes made by external CLI tools that run during earlier hooks.

```json
{ "action": "read", "source": "XMP:Subject", "field": "keywords" }
```

These actions introduce file I/O and require design decisions around: which metadata library to use, supported formats (IPTC/XMP/EXIF), write-back strategy (in-place vs sidecar), error handling for corrupt/missing metadata, and how the pipeline orchestrator coordinates re-reads after external tools modify files. A separate spec will cover these concerns.
