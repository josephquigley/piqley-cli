# Skip Rule Effect — Design Spec

## Summary

Add a `skip` emit action that halts rule evaluation, binary execution, and all downstream pipeline processing for the matched image. When triggered, the image filename and plugin identifier are written to a reserved `skip` namespace. Downstream plugins receive the skip records as a dedicated `skipped` field on the JSON wire payload.

## Motivation

Some images should be excluded from processing based on metadata conditions. For example, images tagged as drafts, duplicates, or already-published should not be sent through the pipeline. Currently there is no declarative way to express "stop processing this image." The skip action makes this a single rule:

```json
{
  "match": { "field": "original:IPTC:Keywords", "pattern": "glob:*Draft*" },
  "emit": { "action": "skip" }
}
```

## JSON Wire Format

### Rule syntax

```json
{
  "match": { "field": "original:IPTC:Keywords", "pattern": "glob:*Draft*" },
  "emit": { "action": "skip" }
}
```

- `action`: must be `"skip"`.
- No other emit fields (`field`, `values`, `replacements`, `source`) are permitted.
- A skip rule must not have a `write` section.

### Skip namespace state

When the skip action fires for image `IMG_001.jpg` from plugin `com.piqley.privacy-strip`, the state store receives:

```json
{
  "skip": {
    "records": [
      { "file": "IMG_001.jpg", "plugin": "com.piqley.privacy-strip" }
    ]
  }
}
```

The `skip` namespace is reserved (alongside `original`). The `records` field contains an array of skip records. The field is named `records` (not `skip`) to avoid confusion with the namespace name.

**StateStore mapping:** The StateStore is keyed per-image: `images[imageName][namespace][field]`. The skip record is written under the skipped image's own state: `images["IMG_001.jpg"]["skip"]["records"]`. Each image's skip namespace holds a single-element array with its own skip record. This fits the existing StateStore model without changes.

For pipeline-level skip checking (fast lookup), the orchestrator maintains a separate `skippedImages: Set<String>` that is populated alongside StateStore writes. This avoids scanning all images' skip namespaces to determine if an image is skipped. The StateStore write provides durability for downstream rule matching and plugin wire payloads. The set provides O(1) lookup for the pipeline loop.

When building the `skipped` array for the plugin wire payload, the orchestrator collects skip records from the StateStore across all images in `skippedImages`.

### Matching against skip

Downstream rules can match against skip using the special `skip` match field without a namespace prefix:

```json
{
  "match": { "field": "skip", "pattern": "glob:IMG_001*" },
  "emit": { "action": "add", "field": "status", "values": ["was-skipped"] }
}
```

The evaluator resolves `skip` as a special match field by reading the `skip` namespace's `records` field, extracting the `file` values, and checking whether the current image's filename matches the pattern. The match only fires when the current image being evaluated is itself in the skip list.

### Plugin wire payload

Plugin binaries receive skip records as a top-level `skipped` field on the request, separate from `state`:

```json
{
  "images": ["IMG_002.jpg"],
  "state": { ... },
  "skipped": [
    { "file": "IMG_001.jpg", "plugin": "com.piqley.privacy-strip" }
  ]
}
```

Skipped images are not included in `images`. The `skipped` array lets plugins inspect what was filtered and by whom.

### Field summary

| Action | `field` | `values` | `replacements` | `source` |
|--------|---------|----------|----------------|----------|
| add (default) | required | values to add | — | — |
| remove | required | values/patterns to remove | — | — |
| replace | required | — | ordered pattern-to-replacement mappings | — |
| removeField | required (or `"*"`) | — | — | — |
| clone | required (or `"*"`) | — | — | required |
| skip | — | — | — | — |

## Pipeline Behavior

When a skip action fires during rule evaluation for a given image:

1. **Immediate halt.** Remaining rules in the current pre-rules or post-rules list are not evaluated for that image.
2. **Binary skipped.** If skip came from pre-rules, the plugin binary is not invoked for that image. If skip came from post-rules, the binary already ran, but downstream effects stop.
3. **Downstream plugins skip the image.** Before processing any image, the pipeline checks the skip namespace. If the image is present, it skips all rules and binary execution for that image in the current and all subsequent plugins.
4. **Other images unaffected.** The pipeline continues processing the rest of the batch normally.

The skip check happens at the top of the per-image loop in `PipelineOrchestrator`, before pre-rules evaluation. The skip write happens inside `RuleEvaluator` when the action fires.

## PiqleyCore Changes

### EmitConfig

`EmitConfig.field` changes from `String` to `String?`. This is a source-breaking change: all existing call sites (PiqleyCore, CLI, SDK) must pass `field:` as an optional. The `init` signature becomes:

```swift
public struct EmitConfig: Codable, Sendable, Equatable {
    public let action: String?
    public let field: String?
    public let values: [String]?
    public let replacements: [Replacement]?
    public let source: String?

    public init(action: String?, field: String?, values: [String]?, replacements: [Replacement]?, source: String?) { ... }
}
```

For skip, `field` is nil. For all other actions, `field` remains required (enforced by `RuleValidator`). Existing SDK `toEmitConfig()` call sites pass non-optional `String` for `field`, which implicitly promotes to `String?` with no source changes needed. Only the new `.skip` case passes `nil`.

### RuleValidator

- Add `"skip"` to `validActions`.
- Restructure `validateEmit`: check the action first, then validate fields per action. The current `guard !emit.field.isEmpty` at the top must move into the per-action branches (add, remove, replace, removeField, clone) so that skip can pass with a nil field.
- Skip emit must have nil `field`, `values`, `replacements`, and `source`.
- New rule-level validation method `validateRule(_:)`: a rule with any `emit.action == "skip"` must have an empty `write` array. This is a rule-level constraint, not an emit-level one, so it cannot live in `validateEmit`.
- Skip must be the only emit action in the array. Validation rejects `emit: [.skip, .add(...)]` since actions after skip would never execute.

### RuleValidationError

- Add `case skipWithWrite` for rules that combine skip with write actions.
- Add `case skipNotAlone` for emit arrays that mix skip with other actions.
- Update `recoverySuggestion` for `.unknownAction` to generate the action list from `RuleValidator.validActions` instead of hardcoding.

### Reserved Namespaces

Add `"skip"` to the reserved namespace list alongside `"original"`. Plugin identifiers cannot use these names.

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
    case skip
}
```

### RuleEvaluator — Compilation

`compileEmitAction` adds a `"skip"` case:

- `field`, `values`, `replacements`, `source` must all be nil/absent.
- Returns `.skip`.

Since `EmitConfig.field` becomes `String?`, all existing action branches (`add`, `remove`, `replace`, `removeField`, `clone`) must guard-unwrap `config.field` (previously non-optional). Validation ensures it is non-nil for these actions, so force-unwrap after validation is safe, but a guard with a descriptive error is cleaner.

The `applyAction(_:to:)` static method needs a `case .skip: break` for exhaustive switch coverage, even though `.skip` is handled before `applyAction` is reached.

### RuleEvaluator — Evaluation

The `evaluate` method's return type changes from `[String: JSONValue]` to a result struct:

```swift
struct RuleEvaluationResult {
    let namespace: [String: JSONValue]
    let skipped: Bool
}
```

When `.skip` is encountered during emit action processing:

1. Write a skip record to the `skip` namespace in the state store. The record is constructed as `JSONValue.object(["file": .string(imageName), "plugin": .string(pluginId)])` and appended to the `records` array. The `SkipRecord` type lives in the SDK; the CLI constructs the equivalent `JSONValue` directly.
2. Stop processing remaining emit actions and remaining rules.
3. Return `RuleEvaluationResult(namespace: working, skipped: true)`.

The `skipped` flag propagates up to `evaluateRuleset` and the orchestrator.

### Match field resolution

When the match field is `"skip"` (no namespace prefix, parsed by `splitField` as namespace="" field="skip"), the evaluator resolves it specially:

1. Reads the `skip` namespace's `records` field from the current image's resolved state.
2. Extracts `file` values from the array of skip records.
3. Matches the current image's filename against the rule's pattern using standard tag matchers.

This means the match checks "is the current image in the skip list and does its filename match the pattern," not "does any skip record match." The match only fires when the current image being evaluated is itself a skipped image.

The `resolve()` call in `evaluateRuleset` must include `"skip"` in its dependencies list so the evaluator can see skip records: `manifestDeps + [ReservedName.original, ReservedName.skip, ctx.pluginIdentifier]`.

### PipelineOrchestrator — evaluateRuleset

The per-image skip check lives in `evaluateRuleset` (which already has the per-image loop), not directly in the orchestrator's hook loop:

1. Before evaluating rules for each image, check the skip namespace for the current image filename.
2. If present, skip rule evaluation for this image entirely.
3. If `evaluate` returns `skipped: true`, propagate this so the orchestrator knows to skip the binary for this image.

`evaluateRuleset` returns a richer result to communicate which images were skipped:

```swift
struct RulesetResult {
    let didRun: Bool
    let skippedImages: Set<String>
}
```

### PipelineOrchestrator — runPluginHook

After pre-rules, the orchestrator uses `skippedImages` to filter images before binary execution. The binary receives only non-skipped images. The `skipped` array is included in the binary's JSON payload.

For binary execution: the current `runBinary` passes the temp folder and the binary discovers images by scanning. The binary payload's `images` list (for JSON protocol plugins) excludes skipped images. The `skipped` array is added as a sibling to `state` in the payload. Plain/exec protocol plugins that scan the folder will still see the files, but JSON protocol plugins get the filtered list.

After post-rules, any newly skipped images are added to the skip set for downstream plugins.

## PiqleyPluginSDK Changes

### SkipRecord

New struct on the SDK:

```swift
public struct SkipRecord: Codable, Sendable, Equatable {
    public let file: String
    public let plugin: String

    public init(file: String, plugin: String) {
        self.file = file
        self.plugin = plugin
    }
}
```

### Plugin Request

Add `skipped: [SkipRecord]` to the plugin request payload type. The field must decode as optional with a default of `[]` (via `decodeIfPresent`) so that existing serialized payloads without `skipped` remain backwards-compatible. The same treatment applies to `PluginInputPayload` in PiqleyCore if it exists as a shared type.

### RuleEmit

Add skip case:

```swift
public enum RuleEmit: Sendable {
    // existing cases...
    case skip
}
```

`toEmitConfig()` mapping (note `field: nil` since `EmitConfig.field` is now `String?`):

```swift
case .skip:
    EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)
```

### Builder DSL example

```swift
ConfigRule(
    match: .field(.original(.iptcKeywords), pattern: .glob("*Draft*")),
    emit: [.skip]
)
```

## Validation

| Constraint | Behavior |
|---|---|
| `skip`: `field` must be absent | Error |
| `skip`: `values` must be absent | Error |
| `skip`: `replacements` must be absent | Error |
| `skip`: `source` must be absent | Error |
| `skip`: rule must not have a `write` section | Error |
| Plugin namespace must not be `"skip"` or `"original"` | Error |

## Scope

### In scope

- `"skip"` action in emit
- Skip namespace as reserved, alongside `original`
- `EmitAction.skip` case in CLI
- Skip handling in `RuleEvaluator.evaluate` with halt signal
- Pipeline-level skip check in `PipelineOrchestrator`
- Special `skip` match field resolution
- `SkipRecord` struct in SDK
- `skipped` field on plugin request payload
- SDK `RuleEmit.skip` case and builder DSL

### Out of scope

- Skip in `write` actions (skip is emit-only, it modifies pipeline flow, not file metadata)
- Skip reason or additional metadata beyond file and plugin (extensible via the record structure later)
- UI/TUI display of skipped images (can be added separately)
- Skip enforcement for plain/exec protocol plugins (these scan the temp folder directly and will still see skipped files on disk; JSON protocol plugins get filtered `images` lists)
