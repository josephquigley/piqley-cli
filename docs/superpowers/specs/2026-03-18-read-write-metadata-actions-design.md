# Read/Write Metadata Actions — Design Spec

## Summary

Add the ability for declarative rules to read current image file metadata and write metadata back to image files. Reading uses a `read:` namespace prefix on match fields. Writing uses a new `write` array on `Rule` that shares the `EmitConfig` type. A per-plugin `MetadataBuffer` handles lazy extraction and batched write-back.

## Motivation

Plugins may shell out to external CLI tools (e.g., ExifTool, ImageMagick) during hook execution that modify image metadata. Currently there is no declarative way to observe those changes or write metadata back to the image file. Plugins that want to tag images must implement a binary — even for simple "add this IPTC keyword" workflows.

## Read: `read:` Namespace

### Concept

`read` is a namespace prefix on `MatchConfig.field`, just like `original` or a plugin name. When the rule evaluator encounters a `read:` field reference, it triggers a metadata extraction from the current image file on disk.

Unlike `original` (populated once at pipeline start), `read` reflects the file's current state — including any modifications made by upstream plugins' binaries or write actions.

### JSON Format

```json
{
  "match": {
    "field": "read:IPTC:Keywords",
    "pattern": "glob:*landscape*",
    "hook": "post-process"
  },
  "emit": [
    { "action": "add", "field": "keywords", "values": ["landscape-photo"] }
  ]
}
```

The field format is `read:<Group>:<Key>`, using the same `Group:Key` naming as the existing metadata extractor (e.g., `EXIF:DateTimeOriginal`, `IPTC:Keywords`, `TIFF:Model`).

The existing `RuleEvaluator.splitField()` splits on the first colon only, producing namespace `"read"` and field `"IPTC:Keywords"`. The compound field maps directly to the flat keys returned by `MetadataExtractor.extract()` — no further splitting is needed.

### Behavior

When the rule evaluator resolves a `read:` namespace field:

1. It asks the `MetadataBuffer` for the image's metadata.
2. If the buffer hasn't loaded this image yet, it extracts all metadata from disk via `MetadataExtractor.extract()` and caches the result for the duration of this plugin execution.
3. The requested field value is returned for pattern matching.

Multiple `read:` fields across different rules within the same plugin execution share the same extracted metadata — the file is read at most once per plugin per image.

## Write: `write` Array on Rule

### Concept

`write` is a new top-level array on `Rule`, sibling to `emit`. It uses the same `EmitConfig` type. While `emit` actions target the plugin's in-memory namespace in the `StateStore`, `write` actions target the image file's metadata via the `MetadataBuffer`.

### JSON Format

```json
{
  "match": { "field": "original:TIFF:Model", "pattern": "regex:.*Canon.*" },
  "emit": [
    { "action": "add", "field": "keywords", "values": ["canon"] }
  ],
  "write": [
    { "action": "add", "field": "IPTC:Keywords", "values": ["canon", "piqley-processed"] },
    { "action": "remove", "field": "IPTC:Keywords", "values": ["glob:temp-*"] }
  ]
}
```

### Supported Actions

All four emit actions work on write targets:

| Action | Behavior |
|--------|----------|
| add | Append values to a metadata field, deduplicating |
| remove | Remove matching values from a metadata field |
| replace | Replace matching values in a metadata field |
| removeField | Delete a metadata field (or `"*"` for all) |

### Rules Without Emit

A rule can have `write` without `emit`, or vice versa, or both. A write-only rule modifies the file without touching plugin state:

```json
{
  "match": { "field": "original:TIFF:Make", "pattern": "glob:*Kodak*" },
  "write": [
    { "action": "add", "field": "IPTC:Keywords", "values": ["film"] }
  ]
}
```

## MetadataBuffer

### Concept

A per-plugin-execution actor that manages lazy metadata extraction and batched write-back. Each plugin execution within a hook gets its own fresh instance — no state carries over between plugins, and no state carries over between hooks for the same plugin.

### Lifecycle

For each plugin + hook execution:

1. Orchestrator creates a new `MetadataBuffer` with image file URLs.
2. `MetadataBuffer` is passed to `RuleEvaluator.evaluate()`.
3. During evaluation:
   - `read:` namespace access triggers `MetadataBuffer.load(image:)` — extracts from disk on first access, returns cached metadata on subsequent access.
   - `write` actions call `MetadataBuffer.applyAction(_:image:)` — loads metadata if not yet cached, applies the action against the in-memory metadata dictionary, marks the image as dirty.
4. After evaluation, orchestrator calls `MetadataBuffer.flush()` — writes modified metadata to disk for all dirty images.
5. Plugin binary runs (if configured) — may also modify files.
6. Buffer is discarded.

### Interface

```swift
actor MetadataBuffer {
    private var metadata: [String: [String: JSONValue]]  // image filename → metadata
    private var dirty: Set<String>
    private let imageURLs: [String: URL]

    init(imageURLs: [String: URL])

    /// Load metadata for an image. Extracts from disk on first call, returns cached on subsequent.
    func load(image: String) async -> [String: JSONValue]

    /// Apply a pre-compiled write action against an image's metadata.
    /// Reuses the same `RuleEvaluator.applyAction(_:to:)` logic internally —
    /// the buffer's metadata dictionary has the same `[String: JSONValue]` shape.
    func applyAction(_ action: EmitAction, image: String) async

    /// Flush all dirty images to disk.
    func flush() async throws
}
```

Reads and writes operate against the same in-memory dictionary, so ordering within a single rule evaluation is consistent — a `read:` after a `write` in the same evaluation sees the written values.

## MetadataWriter (macOS)

Writes metadata back to image files using CoreGraphics' ImageIO framework:

1. Create `CGImageSource` from the file.
2. Create `CGImageDestination` targeting a temporary file (same UTI as source).
3. Call `addImageFromSource(_:index:properties:)` — copies compressed image data as-is, only modifies metadata segments. No decode/re-encode of pixel data.
4. Finalize the destination.
5. Replace the original file with the temporary file.

On Linux, the writer is a no-op stub — same pattern as the existing `MetadataExtractor`.

### Metadata Key Mapping

The `MetadataExtractor` flattens metadata into `Group:Key` format (e.g., `EXIF:DateTimeOriginal`). The writer must reverse this mapping to construct the nested `CGImageProperties` dictionaries that `CGImageDestination` expects:

| Prefix | CGImageProperties dictionary key |
|--------|----------------------------------|
| `EXIF:` | `kCGImagePropertyExifDictionary` |
| `IPTC:` | `kCGImagePropertyIPTCDictionary` |
| `TIFF:` | `kCGImagePropertyTIFFDictionary` |
| `GPS:` | `kCGImagePropertyGPSDictionary` |
| `JFIF:` | `kCGImagePropertyJFIFDictionary` |

## PiqleyCore Changes

### Rule

Add `write` array:

```swift
public struct Rule: Codable, Sendable, Equatable {
    public let match: MatchConfig
    public let emit: [EmitConfig]
    public let write: [EmitConfig]

    public init(match: MatchConfig, emit: [EmitConfig], write: [EmitConfig] = []) {
        self.match = match
        self.emit = emit
        self.write = write
    }
}
```

`write` defaults to `[]` in both `init` and `Decodable` (via `decodeIfPresent`, same pattern as `PluginConfig.rules`). Existing JSON without a `"write"` key decodes as an empty array.

### EmitConfig

No changes. The same type is used for both `emit` and `write`.

### MatchConfig

No changes. The `read:` prefix is parsed the same way as `original:` — the namespace is `read`, the field is everything after the first colon.

## CLI Changes

### RuleEvaluator

The `evaluate` method becomes `async` and gains `metadataBuffer` and `imageName` parameters:

```swift
func evaluate(
    hook: String,
    state: [String: [String: JSONValue]],
    currentNamespace: [String: JSONValue] = [:],
    metadataBuffer: MetadataBuffer? = nil,
    imageName: String? = nil
) async -> [String: JSONValue]
```

The method becomes `async` because resolving `read:` namespace fields and applying `write` actions require calling into the `MetadataBuffer` actor.

The return type stays `[String: JSONValue]` (the updated plugin namespace). Write actions are applied directly to the `MetadataBuffer` during evaluation — no intermediate result type needed.

When resolving match fields:
- If namespace is `"read"` and `metadataBuffer` is non-nil, call `await metadataBuffer.load(image:)` and look up the field in the returned metadata.
- Otherwise, resolve from the `state` dictionary as before.

When a matched rule has `writeActions`, call `await metadataBuffer.applyAction(_:image:)` for each one.

Within a single matched rule, `emit` actions are applied before `write` actions.

### CompiledRule

Add compiled write actions. `write` configs are compiled into `[EmitAction]` at `RuleEvaluator.init` time, same as `emit` — the `MetadataBuffer` receives pre-compiled actions, not raw `EmitConfig`:

```swift
struct CompiledRule: Sendable {
    let hook: String
    let namespace: String
    let field: String
    let matcher: any TagMatcher & Sendable
    let emitActions: [EmitAction]
    let writeActions: [EmitAction]
}
```

### PipelineOrchestrator

Update the rule evaluation flow in `evaluateRules`:

The orchestrator builds `imageURLs` from the image files array it already has (mapping `lastPathComponent` to URL):

```swift
let imageURLs = Dictionary(uniqueKeysWithValues: imageFiles.map { ($0.lastPathComponent, $0) })
let buffer = MetadataBuffer(imageURLs: imageURLs)
for imageName in await ctx.stateStore.allImageNames {
    let resolved = await ctx.stateStore.resolve(...)
    let currentNamespace = resolved[ctx.pluginName] ?? [:]
    let updatedNamespace = await evaluator.evaluate(
        hook: ctx.hook,
        state: resolved,
        currentNamespace: currentNamespace,
        metadataBuffer: buffer,
        imageName: imageName
    )
    if updatedNamespace != currentNamespace {
        await ctx.stateStore.setNamespace(
            image: imageName, plugin: ctx.pluginName, values: updatedNamespace
        )
        didRun = true
    }
}
try await buffer.flush()
// then run binary if configured
```

## PiqleyPluginSDK Changes

### MatchField

Add a `.read(_:)` factory method for `read:` namespace references:

```swift
extension MatchField {
    /// Reference a field from the current image file metadata (read: namespace).
    public static func read(_ key: String) -> MatchField {
        MatchField(encoded: "read:\(key)")
    }
}
```

### ConfigRule

Add `write` array:

```swift
public struct ConfigRule: Sendable {
    let match: RuleMatch
    let emit: [RuleEmit]
    let write: [RuleEmit]

    public init(match: RuleMatch, emit: [RuleEmit] = [], write: [RuleEmit] = []) {
        self.match = match
        self.emit = emit
        self.write = write
    }

    func toRule() -> Rule {
        Rule(
            match: match.toMatchConfig(),
            emit: emit.map { $0.toEmitConfig() },
            write: write.map { $0.toEmitConfig() }
        )
    }
}
```

### Builder DSL Example

```swift
ConfigRule(
    match: .field(.original(.model), pattern: .regex(".*Canon.*"), hook: .preProcess),
    emit: [.keywords(["canon"])],
    write: [.values(field: "IPTC:Keywords", ["canon", "piqley-processed"])]
)

// Read from current file state, write back
// MatchField.read("IPTC:Keywords") is a new factory method (encodes to "read:IPTC:Keywords")
ConfigRule(
    match: .field(
        .read("IPTC:Keywords"),
        pattern: .glob("*landscape*"),
        hook: .postProcess
    ),
    emit: [.keywords(["landscape-photo"])],
    write: [.remove(field: "IPTC:Keywords", ["glob:temp-*"])]
)
```

## Validation

All existing `EmitConfig` validation rules apply to `write` entries:

| Constraint | Behavior |
|---|---|
| `field` must be non-empty | Error |
| `add`: `values` must be non-empty, `replacements` absent | Error |
| `remove`: `values` must be non-empty, `replacements` absent | Error |
| `replace`: `replacements` must be non-empty, `values` absent | Error |
| `removeField`: `values` and `replacements` absent | Error |
| Unknown action | Error |

No additional validation on metadata key format — invalid keys will simply not match any existing metadata or produce no-op writes.

## Error Handling

| Condition | Behavior |
|---|---|
| `MetadataExtractor.extract()` fails or returns empty | `read:` fields return no match (rule skipped) |
| `CGImageDestination` write fails | Error logged, pipeline continues (non-fatal) |
| Image file missing at flush time | Error logged, skip that image |
| Linux platform | Write flush is a no-op with warning logged |
