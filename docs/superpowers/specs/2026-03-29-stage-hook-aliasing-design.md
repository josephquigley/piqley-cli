# Stage Hook Aliasing Design

## Problem

Custom stages (e.g., `publish-365-project`) allow running a plugin multiple times with different rules, but compiled plugin binaries only recognize the hooks they were built with. A plugin like Ghost CMS Publisher handles `publish` but has no knowledge of `publish-365-project`. When the orchestrator passes the custom stage name as the hook string, the plugin throws `unknownHook`.

## Goal

Let custom stages alias to a hook the plugin already supports, so the plugin binary receives a recognized hook while the pipeline uses custom stage names for rule file selection, ordering, and logging.

## Design

### Model Change: `StageEntry.hook`

Add an optional `hook` field to `StageEntry` in PiqleyCore:

```swift
public struct StageEntry: Codable, Sendable, Equatable {
    public var name: String
    public var hook: String?
}
```

When `hook` is non-nil, the orchestrator sends it to the plugin binary instead of the stage name. When `hook` is nil, the stage name is used as the hook (current behavior).

### stages.json Example

```json
{
  "schemaVersion": 1,
  "active": [
    { "name": "pipeline-start" },
    { "name": "pre-process" },
    { "name": "post-process" },
    { "name": "publish" },
    { "name": "publish-365-project", "hook": "publish" },
    { "name": "post-publish" },
    { "name": "pipeline-finished" }
  ],
  "available": []
}
```

### StageRegistry Additions

A resolver method returns the effective hook for any stage:

```swift
public func resolvedHook(for stage: String) -> String {
    if let entry = active.first(where: { $0.name == stage }),
       let hook = entry.hook {
        return hook
    }
    return stage
}
```

### HookContext Changes

`HookContext` gains a `stage` field to preserve the original stage name:

```swift
struct HookContext {
    let pluginIdentifier: String
    let pluginName: String
    let hook: String    // resolved alias, sent to plugin binary
    let stage: String   // original stage name, used for rules/logs/caching
    // ... remaining fields unchanged
}
```

### What Uses Which Identifier

| Concern | Uses `stage` | Uses `hook` |
|---|---|---|
| Rule file lookup (`loadedPlugin.stages[...]`) | yes | |
| Rule evaluator cache keys | yes | |
| Log messages | yes | |
| Pipeline execution order | yes | |
| `executedPlugins` tracking | yes | |
| Hook string to plugin binary (JSON payload) | | yes |
| HookConfig (binary config from stage file) | yes | |
| `PIQLEY_HOOK` environment variable | | yes |

### Orchestrator Changes

In `PipelineOrchestrator.run()`, resolve the hook before creating `HookContext`:

```swift
for stage in registry.executionOrder {
    let resolvedHook = registry.resolvedHook(for: stage)
    for pluginEntry in pipeline[stage] ?? [] {
        let ctx = HookContext(
            pluginIdentifier: pluginEntry,
            pluginName: pluginEntry,
            hook: resolvedHook,
            stage: stage,
            ...
        )
    }
}
```

In `runPluginHook`, rule file lookup uses `ctx.stage`:

```swift
guard let stageConfig = loadedPlugin.stages[ctx.stage] else { ... }
```

Binary execution passes `ctx.hook` as the hook string in the plugin payload:

```swift
runner.run(hook: ctx.hook, hookConfig: stageConfig.binary, ...)
```

The binary config (`stageConfig.binary`) still comes from the custom stage's own rule file (`stage-publish-365-project.json`). Only the hook string in the payload/environment changes.

### Validation

At configuration time (TUI stage editor), when a user sets a `hook` alias:

- The alias target must pass `StageRegistry.isValidName`
- The target should be a hook that at least one plugin in the workflow vends (has a `stage-<hook>.json` or manifest entry for). This is a warning, not a hard error, since plugins can be installed later.

### Backward Compatibility

- `hook` is optional and defaults to nil. Existing `stages.json` files decode without changes.
- `schemaVersion` remains 1 (additive field).
- Standard stages without `hook` behave identically to today.
- No plugin-side changes required.

## Testing

- **StageRegistry unit tests**: `resolvedHook(for:)` returns alias when set, stage name when nil.
- **StageEntry coding tests**: round-trip encoding with and without `hook` field.
- **PipelineOrchestrator tests**: verify aliased stage sends resolved hook to plugin binary while using stage name for rule file lookup.
- **Integration test**: a plugin assigned to a custom stage with a hook alias runs successfully using the aliased hook's binary logic.
