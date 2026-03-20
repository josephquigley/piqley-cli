# Pipeline Gaps — Design Spec

## Summary

Five changes to close gaps before plugin dogfooding begins: expanded image format support with warnings, rule negation and clone wildcard, fork/COW pipeline with DAG-based image isolation, a non-interactive `config add-plugin` command, and updated plugin skeleton with hook branching.

## Motivation

Building a Ghost publisher plugin (and future plugins like Flickr, 365 Project, Backblaze archival) exposes friction points in the current pipeline. Images are silently filtered, metadata rules can only build block-lists (not allow-lists), all plugins share one mutable image folder, adding plugins to the pipeline requires manual JSON editing, and the skeleton doesn't show multi-stage patterns. These gaps block effective dogfooding.

---

## 1. Image Format Support + Warnings

### Current behavior

`TempFolder.imageExtensions` is hardcoded to `["jpg", "jpeg", "jxl"]`. Files in other formats are silently ignored. A source directory containing only unsupported files completes "successfully" with zero images processed.

### Changes

**Expand supported formats** to all formats ImageIO handles natively on macOS:

```swift
static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "jxl", "png", "tiff", "tif", "heic", "heif", "webp"
]
```

**Log warnings** when files are skipped. `TempFolder.copyImages()` collects filenames of non-hidden files with unsupported extensions and returns them alongside the copied files. `PipelineOrchestrator` logs one warning per skipped file:

```
warning: Skipping 'photo.cr3': unsupported format
```

**Abort on zero images.** If copying produces zero supported files, log an error and abort the pipeline.

### Plugin format declarations

Plugins may declare format preferences in their manifest:

```json
{
  "supportedFormats": ["jpg", "jpeg", "png"],
  "conversionFormat": "jpg"
}
```

| `supportedFormats` | `conversionFormat` | Behavior |
|---|---|---|
| declared | declared | Unsupported files converted to `conversionFormat`; plugin gets a fork |
| declared | nil | Unsupported files skipped with warning |
| nil | nil | Plugin accepts everything |
| nil | declared | Validation error: `conversionFormat` requires `supportedFormats` |

`conversionFormat` need not be a member of `supportedFormats`. It is the target format for files that fall outside the supported set.

Conversion uses `CGImageDestination` (already a dependency via MetadataExtractor). Specifying `conversionFormat` implicitly triggers a fork (see Section 3). Format conversion happens once, when the fork is first created (the plugin's earliest stage). Since forks persist across stages (Section 3, "Fork lifetime"), converted files carry forward to subsequent stages without re-conversion.

### Files touched

- `TempFolder.swift` in piqley-cli — expanded extensions, return skipped file list
- `PipelineOrchestrator.swift` in piqley-cli — log warnings, abort on zero images
- `PluginManifest` in PiqleyCore — `supportedFormats: [String]?`, `conversionFormat: String?`
- `ManifestValidator` in PiqleyCore — reject `conversionFormat` without `supportedFormats`
- `PluginRequest.swift` in piqley-plugin-sdk — update `imageExtensions` to match `TempFolder.imageExtensions`

---

## 2. Rule Negation + Clone Wildcard

### Match-side negation

Add `not: Bool?` to `MatchConfig`. Defaults to `false`/nil. When `true`, the match condition inverts: emit/write actions fire when the pattern does NOT match.

```json
{
  "match": {"field": "original:IPTC:Keywords", "pattern": "portfolio", "not": true},
  "emit": [{"action": "skip"}]
}
```

"Skip any image whose keywords don't contain 'portfolio'."

### Emit-side negation

Add `not: Bool?` to `EmitConfig`. Only valid on `remove` and `removeField`.

- `remove` + `not: true`: keep only matching values, remove everything else (allow-list for values)
- `removeField` + `not: true`: keep only this field, remove all others (allow-list for fields)

```json
{
  "match": {"field": "original:IPTC:Keywords", "pattern": "regex:.*"},
  "write": [
    {"action": "removeField", "field": "IPTC:Keywords", "not": true},
    {"action": "remove", "field": "IPTC:Keywords", "values": ["landscape", "portrait"], "not": true}
  ]
}
```

"Strip all metadata fields except IPTC:Keywords, then keep only 'landscape' and 'portrait'."

### Validation

- `not: true` is valid on: match conditions, `remove`, `removeField`
- `not: true` is rejected on: `add`, `replace`, `clone`, `skip`, `writeBack`
- Negation on constructive/non-filtering actions has no meaningful semantics
- Negation semantics apply identically in both `emit` and `write` arrays. The `RuleEvaluator` uses the same `applyAction` logic for both contexts.

### Clone wildcard (already implemented)

`clone` with `field: "*"` copies all fields from the source namespace. This is already implemented in `RuleEvaluator` and the SDK (`RuleEmit.cloneAll`). No code changes needed; this section documents it for completeness since it composes with the new negation features.

```json
{"action": "clone", "field": "*", "source": "original"}
```

"Copy all original metadata into my plugin's namespace."

Combined with `removeField` + `not: true`, this enables: "clone everything from original, then keep only what I want."

### Files touched

- `MatchConfig` in PiqleyCore — add `not: Bool?`
- `EmitConfig` in PiqleyCore — add `not: Bool?`
- `RuleValidator` in PiqleyCore — validate `not` constraints
- `RuleEvaluator` in piqley-cli — invert match logic, invert remove/removeField
- `ConfigBuilder.swift` in piqley-plugin-sdk — add `not` parameter to `RuleMatch.toMatchConfig()` and `RuleEmit.toEmitConfig()`
- `MatchField.swift` in piqley-plugin-sdk — ergonomic `not` support on match builders

---

## 3. Fork/COW Pipeline

### Concept

Plugins sometimes need to destructively modify images (resize, strip metadata, recompress) without affecting downstream plugins that expect the originals. The fork system provides copy-on-write isolation managed entirely by the CLI.

- **Main pipeline** = trunk. Non-forking plugins operate directly on these files.
- **Fork** = COW branch. CLI copies images into a plugin-specific folder.
- **Write-back** = merge to trunk. A `writeBack` rule effect copies fork contents back to main.
- **Fork dependency** = branch from branch. Declaring a dependency on a forking plugin means your fork (or input) comes from that plugin's fork, not main.

### Manifest declaration

Plugins declare fork behavior per stage in `HookConfig`:

```json
{
  "binary": {
    "command": "./bin/resize",
    "fork": true
  }
}
```

`fork: Bool?` defaults to `false`. When `true`, the CLI creates a COW copy before running that stage. Specifying `conversionFormat` in the plugin manifest also implicitly sets `fork: true`.

There is no `writeBack` field on the manifest. Write-back is a rule effect (see below).

### Fork source resolution

When creating a fork, the CLI determines where to copy images from:

1. If the plugin declares dependencies, find the dependency that runs latest in pipeline execution order among those that forked. Use that dependency's fork output as source.
2. If the plugin declares dependencies but none of them forked, copy from main.
3. If the plugin declares no dependencies, copy from main.

**Ambiguity constraint:** If a plugin declares multiple dependencies that forked independently (not in a chain), the CLI uses the one that ran most recently. This is deterministic because plugin execution order within a hook is defined by the pipeline config array. The DAG is always a strict linear order at runtime, even if the logical dependency graph branches.

**Multiple write-backs:** If multiple plugins write back to main in the same pipeline run, last-writer-wins. The pipeline config array determines execution order, so the user controls which write-back is final. The CLI logs a warning when a second writeBack overwrites a previous one:

```
warning: writeBack from 'com.example.plugin-b' overwrites previous writeBack from 'com.example.plugin-a'
```

### Folder structure

```
/tmp/piqley-{uuid}/
  main/                              ← shared pipeline images
  forks/
    com.example.resize/              ← COW from main
    com.example.watermark/           ← COW from resize's fork
    com.example.ghost-preprocess/    ← COW from watermark's fork
    com.example.365-preprocess/      ← COW from watermark's fork (separate)
```

For sandboxed plugins, the CLI copies to the plugin's sandbox container instead of the `forks/` subfolder. Sandbox container discovery and sandboxed-vs-unsandboxed detection is deferred to a future spec. The initial implementation uses `forks/` for all plugins.

### Fork lifetime

A fork folder is created once when the plugin first runs in its earliest stage and persists through all stages until pipeline cleanup. The same physical files carry forward across hooks. A plugin's binary side effects in pre-process (e.g., resized files) are what the publish binary sees.

### Write-back as a rule effect

Write-back is a new rule write action: `"writeBack"`. Valid only in post-rules of a forking plugin's stage. Copies the fork's images back to main.

```json
{
  "postRules": [
    {
      "match": {"field": "original:IPTC:Keywords", "pattern": "regex:.*"},
      "write": [{"action": "writeBack"}]
    }
  ]
}
```

**Validation:**
- `writeBack` must have no `field`, `values`, `replacements`, or `source`
- `writeBack` is only valid in `write` actions, not `emit`
- `writeBack` requires the owning plugin stage to have `fork: true`
- Like `skip`, validation rejects any sibling fields

**Validation location:** `RuleValidator` in PiqleyCore handles structural validation (no sibling fields, write-only). The `fork: true` cross-cutting check lives in `PipelineOrchestrator` at runtime, since `RuleValidator` has no access to `HookConfig` context. The orchestrator validates this when loading stage configs before execution, alongside dependency validation.

**Timing:** Write-back happens when post-rules are evaluated, before the next plugin runs. Subsequent non-dependent plugins see the updated main.

### Payload

`PluginInputPayload` is unchanged. The `imageFolderPath` points to the fork folder instead of main. The plugin does not know or care whether it received a fork or the original. State and dependency state flow through the `state` field as before.

### Workflow example

This example shows how forks compose in a real photography workflow with multiple publishers.

A photographer exports images from Lightroom. The CLI loads them and runs the pipeline:

1. **Privacy Stripper** (no fork) strips GPS coordinates from all images. Operates directly on main.

2. **Resize** (fork from main) creates a COW copy and resizes images to 2000px long edge at 85% quality. Main retains the full-resolution originals.

3. **Watermark** (fork from Resize, depends on Resize) creates a COW copy of the resized images and applies a digital watermark. Resize's fork is unmodified.

4. **Ghost pre-process** (fork from Watermark, depends on Watermark) strips all metadata from the watermarked images, then re-applies only select fields from the `original` namespace (title, copyright, curated keywords).

5. **365 Project pre-process** (fork from Watermark, depends on Watermark) does its own metadata preparation, independent from Ghost. Different metadata choices, same watermarked source.

6. **Ghost publish** uses Ghost pre-process's fork and uploads to Ghost CMS.

7. **365 Project publish** uses 365 pre-process's fork and uploads to the 365 Project platform.

8. **Watermark publish** (writeBack rule effect) copies the resized, watermarked images back to main, overwriting the full-resolution originals.

9. **Backblaze publish** (no fork) archives the main pipeline images, which are now the resized, watermarked versions after Watermark's write-back.

10. **Watermark Database** reads from the watermark namespace state and the Ghost publish output state to record publish URLs alongside watermark metadata.

```
Main ← Privacy Stripper (no fork, modifies main directly)
  │
  ├── Resize (fork from main)
  │     │
  │     └── Watermark (fork from Resize)
  │           │
  │           ├── Ghost pre-process (fork from Watermark)
  │           │     └── Ghost publish (uses Ghost pre-process fork)
  │           │
  │           ├── 365 pre-process (fork from Watermark)
  │           │     └── 365 publish (uses 365 pre-process fork)
  │           │
  │           └── Watermark publish (writeBack → merges to main)
  │
  └── Backblaze publish (no fork, reads main post-writeback)
```

### Files touched

- `HookConfig` in PiqleyCore — `fork: Bool?`
- `RuleValidator` in PiqleyCore — `writeBack` action validation
- `EmitAction` in piqley-cli — new `writeBack` case
- `RuleEvaluator` in piqley-cli — `writeBack` execution
- `PipelineOrchestrator` in piqley-cli — fork creation, DAG resolution, format conversion
- `TempFolder` in piqley-cli — new folder structure with `forks/` subdirectory
- `PluginRunner` in piqley-cli — pass fork path as `imageFolderPath`

---

## 4. `config add-plugin` Command

### New subcommand

```bash
piqley config add-plugin <plugin-identifier> <stage>
```

### Validation

Reuses existing logic extracted from `ConfigWizard.addPlugin()` into a shared function (e.g., `PipelineEditor` type or extension on `AppConfig`):

1. `AppConfig.load()` to get current pipeline
2. `PluginDiscovery.loadManifests()` to verify plugin exists on disk
3. Plugin has a stage file for the target stage
4. Plugin not already in that stage
5. `DependencyValidator.validate()` after tentative addition (loads all manifests and constructs tentative pipeline dictionary, not just the added plugin)

### Options

- `--position <int>`: insert at specific index rather than appending (controls execution order)

### Output

```
Added 'com.example.resize' to pre-process pipeline
```

### Complementary command

`piqley config remove-plugin <plugin-identifier> <stage>` for symmetry. Warns if other plugins depend on the one being removed.

### Implementation

Extract shared validation from `ConfigWizard.addPlugin()` into a standalone function that both the wizard and the new command call. No duplicated validation logic.

### Files touched

- New `AddPluginCommand.swift` in piqley-cli
- New `RemovePluginCommand.swift` in piqley-cli
- `ConfigCommand.swift` — register new subcommands
- `ConfigWizard.swift` — extract validation into shared function
- `AppConfig` or new `PipelineEditor` type — shared validation logic

---

## 5. Plugin Skeleton + Documentation

### Skeleton update

Replace `Skeletons/swift/Sources/main.swift` with hook-branching pattern:

```swift
@main
struct Plugin: PiqleyPlugin {
    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        switch request.hook {
        case .preProcess:
            return try await preProcess(request)
        case .postProcess:
            return try await postProcess(request)
        case .publish:
            return try await publish(request)
        case .postPublish:
            return try await postPublish(request)
        }
    }

    private func preProcess(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add pre-process logic
        return .ok
    }

    private func postProcess(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add post-process logic
        return .ok
    }

    private func publish(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add publish logic
        return .ok
    }

    private func postPublish(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add post-publish logic
        return .ok
    }
}
```

### Documentation updates

**`docs/plugin-sdk-guide.md`:**
- Update "The Plugin Protocol" section to show hook-branching pattern
- Add section on multi-stage plugins (one binary, all stages)
- Add section on format declarations (`supportedFormats`, `conversionFormat`)
- Add section on fork/COW mechanics: how to declare `fork: true`, how `conversionFormat` triggers implicit forking, fork lifetime across stages, how `writeBack` works as a rule effect
- Add section on rule negation (`not` on match and emit) with allow-list examples
- Add section on clone wildcard with composition patterns
- Update manifest example with new fields

**`docs/advanced-topics.md`:**
- Add full workflow narrative example (Privacy Stripper through Watermark Database) demonstrating the fork DAG model and why it matters
- Add rule composition examples showing negation + clone wildcard together

**`docs/getting-started.md`:**
- No forking content. Keep this focused on basics.

### Files touched

- `Skeletons/swift/Sources/main.swift` in piqley-plugin-sdk
- `docs/plugin-sdk-guide.md` in piqley-cli
- `docs/advanced-topics.md` in piqley-cli
