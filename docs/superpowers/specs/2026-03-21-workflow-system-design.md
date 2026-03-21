# Workflow System Design

## Summary

Replace the single `config.json` pipeline with named workflow files. Each workflow is a self-contained JSON file in `~/.config/piqley/workflows/` containing metadata and a pipeline definition. The `process` command gains workflow selection logic, and a new `workflow` command group provides CRUD operations.

## Workflow Model

### File format

Each workflow is stored at `~/.config/piqley/workflows/{name}.json`:

```json
{
  "name": "ghost",
  "displayName": "Ghost Publishing",
  "description": "Resize, watermark, and publish to Ghost",
  "schemaVersion": 1,
  "pipeline": {
    "pre-process": [],
    "post-process": [],
    "publish": [],
    "post-publish": []
  }
}
```

### Workflow struct

```swift
struct Workflow: Codable, Sendable {
    var name: String
    var displayName: String
    var description: String
    var schemaVersion: Int = 1
    var pipeline: [String: [String]]
}
```

The `name` field matches the filename (without `.json`). The pipeline has the same `[String: [String]]` shape as the current `AppConfig.pipeline`.

### WorkflowStore

Stateless enum (like `PipelineEditor`) for workflow file operations:

- `workflowsDirectory` -> `~/.config/piqley/workflows/`
- `list()` -> scan directory, return workflow names
- `load(name:)` -> decode a specific workflow file
- `loadAll()` -> load all workflow files
- `save(workflow:)` -> encode and write to `{name}.json`
- `delete(name:)` -> remove file
- `clone(source:destination:)` -> load source, update name, save as destination
- `exists(name:)` -> check if file exists

## Process Command Changes

### Argument resolution

The command changes from one required positional arg to two optional positional args:

```
piqley process ~/photos              # 1 workflow -> use it
piqley process ~/photos              # 2+ workflows -> error
piqley process ghost ~/photos        # explicit workflow
```

Resolution logic:

1. If both `firstArg` and `secondArg` provided: `firstArg` is workflow name, `secondArg` is folder path.
2. If only `firstArg` provided:
   - List all workflows. If exactly 1 exists, treat `firstArg` as the folder path, use that workflow.
   - If 2+ workflows exist, check if `firstArg` matches a workflow name. If yes, error: "missing folder path." If no match, error: "multiple workflows found, specify which one: `piqley process <workflow> <path>`."

### Orchestrator changes

`PipelineOrchestrator` takes a `Workflow` instead of `AppConfig`. Since the pipeline dict has the same shape, internal orchestrator logic is unchanged.

## Workflow Command Group

New top-level command replacing `ConfigCommand`:

```
piqley workflow edit [name]
piqley workflow create [name]
piqley workflow clone <src> <dst>
piqley workflow delete <name> [--force]
piqley workflow add-plugin <workflow> <plugin-id> <stage> [--position N]
piqley workflow remove-plugin <workflow> <plugin-id> <stage>
```

### workflow edit (no name)

TUI menu listing all workflows. Actions:

- `n` new workflow (prompts for name, creates empty, opens editor)
- `Enter` select workflow to edit stages/plugins (drops into ConfigWizard)
- `d` delete selected workflow (with confirmation)
- `c` clone selected workflow (prompts for new name)
- `Esc` quit

### workflow edit \<name\>

Skips the list, opens ConfigWizard directly for that workflow.

### workflow create [name]

If name provided, creates an empty workflow and opens the editor. If no name, prompts for one first. Shortcut for edit -> new workflow.

### workflow clone \<src\> \<dst\>

Loads source workflow, saves as destination with updated name/displayName. Errors if source doesn't exist or destination already exists.

### workflow delete \<name\> [--force]

Deletes the workflow file. Prompts for confirmation unless `--force` is passed. Errors if the file doesn't exist.

### workflow add-plugin \<workflow\> \<plugin-id\> \<stage\> [--position N]

Loads the named workflow, validates and adds the plugin to the stage, saves. Same logic as the current `config add-plugin` but scoped to a workflow.

### workflow remove-plugin \<workflow\> \<plugin-id\> \<stage\>

Loads the named workflow, validates and removes the plugin from the stage, saves. Same logic as the current `config remove-plugin` but scoped to a workflow.

## Setup Command Changes

New behavior:

1. Install bundled plugins (unchanged).
2. Create `~/.config/piqley/workflows/` directory.
3. Seed a `default` workflow with empty pipeline (all four hooks as empty arrays).
4. If plugins were discovered: prompt for workflow name (defaulting to "default"), then drop into ConfigWizard for that workflow.
5. Run plugin setup scanners (unchanged).

## ConfigWizard Adaptation

- Takes a `Workflow` instead of `AppConfig`.
- The pipeline dict has the same shape, so stage select, plugin list, reorder, add/remove logic is unchanged.
- `save()` calls `WorkflowStore.save(workflow:)`.
- Title bar shows the workflow name, e.g. "Edit Workflow: ghost".

## PipelineEditor Changes

`validateAdd`, `validateRemove`, and `dependents` change their `config: AppConfig` parameter to `workflow: Workflow`.

## Cleanup

### Removed

- `Config.swift` (`AppConfig` struct): replaced by `Workflow`
- `config.json` path from `PiqleyPath`: replaced by `workflows` directory path
- `ConfigCommand`: replaced by `WorkflowCommand`

### Modified

- `PiqleyPath`: add `workflows` directory path, remove `config`
- `PipelineOrchestrator`: takes `Workflow` instead of `AppConfig`
- `PipelineEditor`: parameter type changes from `AppConfig` to `Workflow`
- `Piqley.swift`: swap `ConfigCommand` for `WorkflowCommand` in subcommands list
- `ProcessCommand`: new argument resolution logic, loads workflow via `WorkflowStore`
- `SetupCommand`: new seed + editor flow
- `AddPluginSubcommand`: moves under `WorkflowCommand`, takes workflow name arg
- `RemovePluginSubcommand`: moves under `WorkflowCommand`, takes workflow name arg
