# Command Editor Workflow Scoping

## Problem

`PluginCommandEditCommand` loads and saves stage files from the plugin directory (`~/.config/piqley/plugins/<id>/`), but the pipeline loads stages from the workflow rules directory (`~/.config/piqley/workflows/<name>/rules/<id>/`). This means:

1. Deleting a command via the TUI removes the binary from the plugin-level file but leaves the workflow-scoped copy intact, so the command still runs.
2. Edits to commands are never visible to the pipeline at runtime.

`PluginRulesCommand` already handles this correctly by operating on the workflow rules directory.

## Design

### 1. Shared Argument Resolution: `PluginWorkflowResolver`

Extract the workflow + plugin resolution logic from `PluginRulesCommand` into a new reusable utility.

**Location:** `Sources/piqley/CLI/PluginWorkflowResolver.swift`

**Interface:**

```swift
struct PluginWorkflowResolver {
    let firstArg: String?
    let secondArg: String?
    /// Used in non-interactive error messages, e.g. "piqley plugin rules"
    let usageHint: String

    func resolve() throws -> (workflowName: String, pluginID: String)
}
```

**Resolution logic** (identical to current `PluginRulesCommand`):

- Two args: `(firstArg, secondArg)` treated as `(workflow, plugin)`. Validates the plugin exists in the workflow's pipeline.
- One arg: check if it's a workflow name (prompt for plugin) or a plugin ID (auto-resolve workflow, prompt if multiple).
- No args: interactive selection of workflow, then plugin.
- Non-interactive fallback: throw `CleanError` with the parameterized `usageHint`.

The private helpers `resolveSingleArg`, `resolveNoArgs`, `pipelinePlugins`, and `selectInteractively` move into this struct.

### 2. `PluginRulesCommand` Refactor

Replace the private argument resolution methods with a call to `PluginWorkflowResolver`. No behavior change.

### 3. `PluginCommandEditCommand` Changes

Replace the current plugin-directory logic with:

1. Use `PluginWorkflowResolver` to obtain `(workflowName, pluginID)`.
2. Derive `pluginDir` from `PipelineOrchestrator.defaultPluginsDirectory` (for manifest loading and binary probing only).
3. Derive `rulesDir` from `WorkflowStore.pluginRulesDirectory(workflowName, pluginID)`.
4. Load stages from `rulesDir`.
5. Pass both `pluginDir` and `rulesDir` to `CommandEditWizard`.

### 4. `CommandEditWizard` Changes

**Init signature change:**

```swift
init(
    pluginID: String,
    stages: [String: StageConfig],
    pluginDir: URL,    // read-only: binary probing (resolving relative command paths)
    rulesDir: URL,     // read-write: stage file I/O
    availableFields: [String: [FieldInfo]] = [:]
)
```

**Affected methods:**

- `save()`: writes to `rulesDir` instead of `pluginDir`.
- `quit()`: cleans up empty stage files in `rulesDir`.
- `editCommandBinary()`: continues using `pluginDir` for `BinaryProbe` calls (unchanged).

## Files Changed

| File | Change |
|------|--------|
| `Sources/piqley/CLI/PluginWorkflowResolver.swift` | New file: shared resolution logic |
| `Sources/piqley/CLI/PluginRulesCommand.swift` | Remove private resolution methods, delegate to `PluginWorkflowResolver` |
| `Sources/piqley/CLI/PluginCommandEditCommand.swift` | Use `PluginWorkflowResolver`, pass `rulesDir` to wizard |
| `Sources/piqley/Wizard/CommandEditWizard.swift` | Add `rulesDir` parameter, use it for save/cleanup |

## Out of Scope

- Double-escaped regex backslashes in stage files (separate bug).
- Cross-workflow delete fan-out (not needed since edits are per-workflow).
