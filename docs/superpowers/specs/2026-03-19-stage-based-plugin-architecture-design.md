# Stage-Based Plugin Architecture — Design Spec

## Summary

Rework the plugin system so that each plugin vends separate JSON config files per stage it supports, rather than bundling hook definitions into the manifest. Introduces pre-binary and post-binary rulesets per stage, simplifies the manifest to secrets and dependency tracking, and enables granular per-stage plugin execution ordering.

Changes span PiqleyCore (new `StageConfig` type, manifest slimming), PiqleyPluginSDK (new `StageBuilder`, manifest/config builder changes), and the CLI (discovery, orchestration, MetadataBuffer invalidation).

This is a breaking change. There are no external consumers to migrate.

## Motivation

The current design couples hook configuration (binary command, timeout, protocol) with plugin identity (manifest) and declarative rules (config). This creates several problems:

- Plugin authors cannot apply declarative rules before or after a binary runs within the same stage — rules and binaries are separate concerns evaluated independently.
- All stage definitions live in the manifest, making it a catch-all that mixes identity, secrets, dependencies, and execution config.
- The CLI has no leverage point between "rules ran" and "binary ran" to manipulate state or files.

The new design separates concerns: the manifest handles identity and dependencies, per-stage files handle execution, and pre/post rulesets give plugin authors fine-grained control over state and file manipulation around binary execution.

## File Layout

A plugin directory under `~/.config/piqley/plugins/<name>/`:

```
my-plugin/
├── manifest.json              # name, version, secrets, dependencies, setup
├── config.json                # values, isSetUp (runtime state)
├── stage-pre-process.json     # optional
├── stage-post-process.json    # optional
├── stage-publish.json         # optional
├── stage-post-publish.json    # optional
├── bin/
├── data/
└── logs/
```

### Discovery

The CLI scans for files matching `stage-*.json` in the plugin directory. The stage name is extracted from the filename — `stage-pre-process.json` → hook `pre-process`. If the extracted name is not one of the four canonical hooks (`pre-process`, `post-process`, `publish`, `post-publish`), the CLI warns and skips it.

### Package Format

The `.piqleyplugin` zip archive includes stage files at the top level alongside manifest and config:

```
<plugin-name>/
├── manifest.json
├── config.json
├── stage-pre-process.json     # if present
├── stage-publish.json         # if present
├── bin/
└── data/
```

The build manifest (`piqley-build-manifest.json`) does not enumerate stage files — the packager globs for `stage-*.json` in the project directory.

## manifest.json

The manifest drops the `hooks` field. It retains identity, config schema, dependencies, and setup:

```json
{
  "name": "my-plugin",
  "pluginProtocolVersion": "1",
  "pluginVersion": "1.0.0",
  "config": [
    { "key": "outputFormat", "type": "string", "value": "jpeg" },
    { "secretKey": "API_KEY", "type": "string" }
  ],
  "dependencies": [
    {
      "url": "https://example.com/other-plugin.piqleyplugin",
      "version": { "from": "1.0.0", "rule": "exact" }
    }
  ],
  "setup": {
    "command": "./bin/my-plugin",
    "args": ["--setup"]
  }
}
```

### PiqleyCore Changes

- `PluginManifest` removes the `hooks: [String: HookConfig]` field
- `HookConfig` remains in PiqleyCore — it is reused as the `binary` field within `StageConfig`
- `ConfigEntry`, `SetupConfig`, and dependency types are unchanged

## config.json

Retains only runtime state:

```json
{
  "values": {
    "outputFormat": "jpeg"
  },
  "isSetUp": true
}
```

- `rules` field is removed — rules now live in stage files
- `PluginConfig` in PiqleyCore drops the `rules: [Rule]` field

## Stage File Format

Each `stage-<name>.json` contains up to three optional sections:

```json
{
  "preRules": [
    {
      "match": { "field": "original:TIFF:Model", "pattern": "glob:Canon*" },
      "emit": [{ "field": "keywords", "values": ["canon"] }]
    }
  ],
  "binary": {
    "command": "./bin/my-plugin",
    "args": ["--quality", "high"],
    "timeout": 60,
    "protocol": "json",
    "successCodes": [0],
    "warningCodes": [1],
    "criticalCodes": [2]
  },
  "postRules": [
    {
      "match": { "field": "my-plugin:processedCount", "pattern": "regex:\\d+" },
      "emit": [{ "action": "add", "field": "keywords", "values": ["processed"] }],
      "write": [{ "action": "add", "field": "IPTC:Keywords", "values": ["processed"] }]
    }
  ]
}
```

All three fields are optional. Valid combinations:

| preRules | binary | postRules | Use Case |
|----------|--------|-----------|----------|
| — | — | — | Invalid (empty stage file, CLI warns and skips) |
| yes | — | — | Purely declarative pre-processing |
| — | yes | — | Binary-only (current behavior equivalent) |
| — | — | yes | Purely declarative post-processing |
| yes | yes | — | Set up state before binary |
| — | yes | yes | Process binary output declaratively |
| yes | yes | yes | Full pipeline: prepare, execute, finalize |
| yes | — | yes | Declarative-only with distinct pre/post phases |

### PiqleyCore Changes

New type:

```swift
public struct StageConfig: Codable, Sendable, Equatable {
    public let preRules: [Rule]?
    public let binary: HookConfig?
    public let postRules: [Rule]?
}
```

`Rule`, `MatchConfig`, `EmitConfig`, and `HookConfig` are unchanged — reused across pre and post rulesets and the binary config.

## CLI Loading & Orchestration

### PluginDiscovery

- `LoadedPlugin` gains `stages: [String: StageConfig]` (keyed by hook name, e.g. `"pre-process"`)
- Discovery scans for `stage-*.json` files, parses each into `StageConfig`
- Validation: warns on unknown stage names, warns on empty stage files

### PipelineOrchestrator

Per-plugin-per-hook execution flow:

1. Look up `stages[hookName]` — skip if absent
2. Create `MetadataBuffer` for this stage execution
3. If `preRules` present: compile & evaluate against current state, update plugin namespace
4. Flush buffer (writes any `write` actions from pre-rules to disk)
5. If `binary` present: build payload from post-pre-rules state, run via `PluginRunner`, merge returned state
6. Invalidate buffer cache (binary may have modified files on disk)
7. If `postRules` present: compile & evaluate against post-binary state, update plugin namespace
8. Flush buffer (writes any `write` actions from post-rules to disk)

### State Availability

- **preRules**: Can read `original` namespace, dependency namespaces, and the plugin's current namespace (accumulated from prior stages). Emits to the plugin's namespace.
- **binary**: Receives state as it exists after pre-rules ran.
- **postRules**: Same access as pre-rules, plus whatever the binary returned in the plugin's namespace. The MetadataBuffer cache is invalidated before post-rules run, so `read:` namespace fields re-extract fresh metadata from disk.

### MetadataBuffer Cache Invalidation

After the binary runs, the CLI calls `MetadataBuffer.invalidateAll()` to clear cached metadata. When post-rules access `read:` namespace fields, the buffer re-extracts from disk, reflecting any changes the binary made to the files.

### RuleEvaluator

No changes needed. It already accepts a `[Rule]` array and is called once per ruleset. In the new flow it is called up to twice per stage (once for pre-rules, once for post-rules).

### PluginRunner

No changes. It already accepts a `HookConfig` and runs the binary. It receives that config from `StageConfig.binary` instead of `manifest.hooks[hookName]`.

### Auto-Discovery

Today, plugins are auto-appended to pipeline hooks based on which hooks they declare in the manifest. New behavior: auto-append based on which `stage-*.json` files exist in the plugin directory.

## Per-Stage Execution Ordering

The existing pipeline config structure supports granular per-stage ordering:

```json
{
  "pre-process": ["plugin-a", "plugin-b"],
  "post-process": ["plugin-b", "plugin-a"],
  "publish": ["plugin-b", "plugin-a"],
  "post-publish": ["plugin-a"]
}
```

Each stage has its own ordered list. Plugin A can run before Plugin B in `pre-process` but after Plugin B in `publish`. No changes to the pipeline config structure are needed.

## SDK Builder Changes

### ManifestBuilder

Remove the `Hooks { HookEntry(...) }` block. All other components remain: `Name`, `ProtocolVersion`, `PluginVersion`, `ConfigEntries`, `Setup`, `Dependencies`.

### ConfigBuilder

Remove the `Rules { ... }` block. Retains `Values { ... }` and `IsSetUp`.

### New StageBuilder

Emits a `stage-<name>.json` file. DSL:

```swift
let stage = buildStage {
    PreRules {
        ConfigRule(
            match: .field(.original(.model), pattern: .glob("Canon*")),
            emit: [.keywords(["canon"])]
        )
    }
    Binary(
        command: "./bin/my-plugin",
        args: ["--quality", "high"],
        timeout: 60
    )
    PostRules {
        ConfigRule(
            match: .field(.dependency("my-plugin", key: "status"), pattern: .exact("done")),
            emit: [.keywords(["processed"])],
            write: [.values(field: "IPTC:Keywords", ["processed"])]
        )
    }
}
```

All three blocks are optional. `Binary(...)` maps to `HookConfig` fields. The builder outputs a `StageConfig` which serializes to JSON.

### Skeleton Updates

- Swift skeleton generates `stage-pre-process.json` instead of hooks in the manifest
- `piqley plugin init` creates stage files alongside manifest and config

## Impact on Existing Specs & Plans

### SDK Build & Packaging (`2026-03-18-sdk-build-packaging-design.md`)

- Package format gains `stage-*.json` files at the top level
- Build manifest no longer needs to track stage files — packager globs for them
- Schema files need a new `stage.schema.json` for `StageConfig` validation
- `manifest.schema.json` drops the `hooks` field

### Declarative Mapping Emit Actions (`2026-03-18-declarative-mapping-emit-actions-design.md`)

- `EmitConfig`, `Rule`, `MatchConfig` types are unchanged
- `ConfigRule` in the SDK moves from `ConfigBuilder` to `StageBuilder`
- The `RuleEvaluator` changes in that spec still apply — they just get invoked twice per stage now

### Read/Write Metadata Actions (`2026-03-18-read-write-metadata-actions.md`)

- `MetadataBuffer` invalidation between pre/post rules is a new requirement addressed by this spec
- The `write` array on `Rule` is unchanged
- `MetadataBuffer` needs `invalidateAll()` method

## Testing Strategy

### PiqleyCore

- Decode/encode round-trip tests for `StageConfig` (all optional field combinations)
- Verify `PluginManifest` decodes without `hooks` field
- Verify `PluginConfig` decodes without `rules` field

### PiqleyPluginSDK

- `StageBuilder` emits valid `StageConfig` JSON for all combinations (pre-only, binary-only, post-only, full)
- `ManifestBuilder` no longer emits hooks
- `ConfigBuilder` no longer emits rules
- Schema validation of emitted JSON against `stage.schema.json`

### piqley-cli

- `PluginDiscovery` finds and parses `stage-*.json` files
- `PluginDiscovery` warns on unknown stage names
- `PipelineOrchestrator` executes pre-rules → binary → post-rules in correct order
- `MetadataBuffer` invalidation: post-rules see fresh metadata after binary modifies files
- Auto-discovery appends plugins based on stage files
- End-to-end: plugin with pre-rules + binary + post-rules produces correct final state

## Scope

### In Scope

- `StageConfig` type in PiqleyCore
- Remove `hooks` from `PluginManifest`
- Remove `rules` from `PluginConfig`
- Stage file discovery in CLI
- Pre/post rule evaluation flow in orchestrator
- MetadataBuffer cache invalidation
- `StageBuilder` in SDK
- Update manifest/config builders
- Skeleton and init updates
- `stage.schema.json`

### Out of Scope

- New hook types beyond the existing four
- Plugin registry or remote discovery
- Non-Swift skeleton creation
- Signing or verification of packages
