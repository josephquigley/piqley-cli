# Auto Lifecycle Hooks Design

## Summary

Make `pipeline-start` and `pipeline-finished` automatic: the CLI invokes them for every plugin in the workflow that has a binary, without requiring the user to manually assign plugins to these stages. Remove lifecycle stages from the TUI's stage editor and the workflow's pipeline dictionary.

## Motivation

The original lifecycle design (2026-03-21) required users to manually add plugins to `pipeline-start` and `pipeline-finished` in their workflow config. In practice, no one does this — the Ghost CMS publisher's `pipelineFinished` cleanup handler has never run because the workflow has `"pipeline-finished": []`. Lifecycle hooks should be automatic: if a plugin has a binary and is active in the workflow, it gets lifecycle callbacks.

## Design

### Plugin Collection

The orchestrator collects the set of plugin identifiers to receive lifecycle hooks by:

1. Iterating all **user-configured stages** in the workflow pipeline (excluding `pipeline-start` and `pipeline-finished` themselves).
2. Collecting the unique set of plugin identifiers across those stages.
3. Filtering to plugins whose `LoadedPlugin` has at least one stage with a non-empty binary command.

Order of invocation within lifecycle hooks is undefined.

### Orchestrator Changes

`PipelineOrchestrator.run()` changes from a single loop over `registry.executionOrder` to a three-phase structure:

1. **Pipeline-start phase**: Invoke `pipeline-start` for each collected plugin. If any plugin returns `.critical`, abort the pipeline (same as current behavior for other stages). Secrets and config are resolved per-plugin as usual.

2. **Main stage loop**: Iterate `registry.executionOrder` as today, but **skip** `pipeline-start` and `pipeline-finished` entries. These stages still exist in the registry (for structural consistency) but are no longer iterated in the main loop.

3. **Pipeline-finished phase**: Always runs, even if the main loop failed. Invoke `pipeline-finished` for each collected plugin. Errors are logged but do not affect the pipeline's return value (best-effort).

For lifecycle invocations, the orchestrator calls `runBinary` directly with a minimal `HookContext`. No rules (pre/post) are evaluated — lifecycle hooks are binary-only. The hook name passed to the plugin binary is `"pipeline-start"` or `"pipeline-finished"` as before.

### Stage File Handling

Lifecycle hooks do **not** require `stage-pipeline-start.json` or `stage-pipeline-finished.json` files. The orchestrator constructs a minimal `HookConfig` inline (binary command from the plugin's first discovered stage config, JSON protocol). This means the Ghost plugin's `HookRegistry` returning `nil` for `.pipelineFinished` is fine — the CLI handles invocation directly.

Specifically: the orchestrator finds the plugin's binary command from any existing stage config (the command is the same binary regardless of stage), and invokes it with the lifecycle hook name. The plugin binary already receives the hook name via `PIQLEY_HOOK` and the JSON payload's `hook` field, so it can dispatch internally.

### Workflow Config Changes

Remove `pipeline-start` and `pipeline-finished` keys from the workflow pipeline dictionary. The `Workflow.empty()` factory and any migration code should stop including these keys. Existing workflow files with these keys are handled gracefully: the keys are ignored during pipeline execution and stripped on next save.

### StageRegistry Changes

Add a computed property or static method to distinguish lifecycle stages from user-configurable stages:

```swift
public static let lifecycleStages: Set<String> = Set(
    [StandardHook.pipelineStart, .pipelineFinished].map(\.rawValue)
)

public var userConfigurableOrder: [String] {
    active.map(\.name).filter { !Self.lifecycleStages.contains($0) }
}
```

The `executionOrder` property continues to include lifecycle stages for backward compatibility, but the orchestrator's main loop uses `userConfigurableOrder` instead.

### TUI Changes

In `ConfigWizard`:

- `stageSelect()`: Use `registry.userConfigurableOrder` instead of `registry.executionOrder` to populate the stage list. Lifecycle stages are invisible.
- `drawStageScreen()`: Same filtering — lifecycle stages never appear.
- `addStage()`, `duplicateStage()`, `reorderStage()`: No changes needed (they already operate on the visible list).
- Stage operations (remove, rename, duplicate, activate) already guard against required stages. Hiding them makes this moot but the guards remain as defense-in-depth.

In `ConfigWizard+Plugins.swift`:

- When showing available stages to add a plugin to (the "add to stage" picker in the all-plugins browser), filter out lifecycle stages.

### Plugin SDK

No SDK changes needed. The `StandardHook` enum already includes `pipelineStart` and `pipelineFinished`. Plugins handle (or ignore) these hooks in their binary's request handler as they already do.

### Error Semantics

| Phase | Plugin failure | Effect |
|-------|---------------|--------|
| `pipeline-start` | `.critical` | Abort pipeline, return `false` |
| Main loop | `.critical` | Abort pipeline (existing behavior) |
| `pipeline-finished` | Any error | Log warning, continue to next plugin |

### Existing Workflow Migration

When the wizard saves a workflow, it should strip `pipeline-start` and `pipeline-finished` from the pipeline dictionary if present. No explicit migration command is needed — the keys are simply ignored at runtime and cleaned up on save.

## Files to Modify

### piqley-core
- `Sources/PiqleyCore/Config/StageRegistry.swift` — add `lifecycleStages` set and `userConfigurableOrder` computed property
- `Sources/PiqleyCore/StandardHook.swift` — add `lifecycleStages` static property if placed here instead

### piqley-cli
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift` — three-phase execution, lifecycle plugin collection, skip lifecycle in main loop
- `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift` — helper for lifecycle binary invocation
- `Sources/piqley/Config/Workflow.swift` — remove lifecycle stages from `Workflow.empty()`, strip on save
- `Sources/piqley/Wizard/ConfigWizard.swift` — use `userConfigurableOrder` in `stageSelect()`
- `Sources/piqley/Wizard/ConfigWizard+Stages.swift` — pass filtered stages to `drawStageScreen()`
- `Sources/piqley/Wizard/ConfigWizard+Plugins.swift` — filter lifecycle stages from "add to stage" picker

### Tests
- Pipeline orchestrator tests — verify lifecycle hooks fire automatically, verify best-effort semantics for pipeline-finished, verify pipeline-start failure aborts
- Stage registry tests — verify `userConfigurableOrder` excludes lifecycle stages
- Workflow tests — verify lifecycle keys stripped on save
