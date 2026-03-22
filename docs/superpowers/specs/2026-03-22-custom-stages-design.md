# Custom Stages Design

## Problem

The current stage system defines a fixed set of 6 stages via the `Hook` enum in PiqleyCore. Plugins can only target these predefined stages. This prevents use cases where a plugin needs to run multiple times with different rules, such as a Ghost CMS plugin that publishes regular photos with one set of rules and 356-project photos with different rules but the same binary.

## Solution

Replace the `Hook` enum as the source of truth with a global **stage registry** file. Users can create, duplicate, rename, reorder, and remove stages. Plugins can also introduce new stages via `stage-*.json` files, which are auto-registered on discovery.

## Stage Registry

### Location

`~/.local/share/piqley/stages.json`

### Data Model

```json
{
  "schemaVersion": 1,
  "active": [
    { "name": "pipeline-start" },
    { "name": "pre-process" },
    { "name": "post-process" },
    { "name": "publish" },
    { "name": "post-publish" },
    { "name": "pipeline-finished" }
  ],
  "available": [
    { "name": "publish-356-project" }
  ]
}
```

- **`active`**: Ordered array. Defines execution order. These stages run during pipeline execution.
- **`available`**: Unordered array. Discovered but not yet placed by the user. Plugins can be assigned to these stages, but they do not execute until activated.
- Stage objects are `{ "name": string }`, minimal and extensible later.
- Stage names must match `[a-z0-9][a-z0-9-]*[a-z0-9]` (lowercase alphanumeric and hyphens, no leading/trailing hyphens). This keeps them safe for use in `stage-<name>.json` filenames.

### StageRegistry Struct

Lives in PiqleyCore. Responsibilities:
- Load/save `stages.json`
- Seed defaults (current 6 stages) when file is missing
- Query: is a stage known (active or available)? What is the execution order?
- Mutate: add, remove, rename, reorder, activate, deactivate stages

## Auto-Registration from Plugins

- During `PluginDiscovery.loadStages`, when a `stage-*.json` file has a name not found in either the `active` or `available` lists, it is appended to the `available` list.
- The existing `knownHooks` guard switches from checking `Hook.allCases` to checking all stages in the registry (both lists).
- Plugin authors are responsible for documenting where their custom stages should be placed in the execution order.

## Orchestrator Changes

- `PipelineOrchestrator` reads the `active` list from `StageRegistry` instead of `Hook.canonicalOrder`.
- The lifecycle special-casing for `pipeline-start` and `pipeline-finished` is removed. All stages execute in the flat order defined by the registry. The existing lifecycle hook callbacks (pre-pipeline setup, post-pipeline cleanup) that were tied to these stage names are intentionally removed. Any setup or teardown behavior should be handled by plugins assigned to stages at the appropriate positions.
- If a stage fails, the pipeline stops. No "run even on failure" semantics. This intentionally removes the current best-effort cleanup behavior of `pipeline-finished`. Plugins that need cleanup should handle it internally (e.g. signal handlers, defer blocks) rather than relying on a guaranteed-to-run stage.
- For each active stage, the orchestrator looks up assigned plugins in the workflow's `pipeline` dictionary, same as today.

## TUI Changes (ConfigWizard)

The stage selector screen switches from `Hook.canonicalOrder` to `StageRegistry.active`.

### Menu Options

- **Add stage**: Prompts for a name, inserts into `active` at a user-chosen position.
- **Duplicate stage**: Prompts for a new name, copies the source stage's `stage-*.json` files for each plugin that has one (with the new name), inserts into `active` after the source stage. Binary config inside the copied files is preserved verbatim. The new stage starts with an empty plugin list in workflows; the user assigns plugins via the normal TUI flow.
- **Activate stage**: Shows the `available` list, lets the user pick one and choose a position in `active`.
- **Remove stage**: Removes the selected stage from `active`, moves it to `available`.
- **Rename stage**: Renames the selected stage across the registry, all workflow files that reference it, and all `stage-*.json` files in plugin directories.
- **Reorder**: Move the selected stage up/down in the `active` list.

### Inactive Stage Configuration

The TUI allows entering inactive (available) stages to configure their plugin lists before activation.

## Validation and Editor Changes

- `PipelineEditor.validateAdd` switches from `Hook.allCases` to all stages in the registry (both `active` and `available`). Users can add plugins to inactive stages.
- `PipelineEditor.validateRemove` gets the same change.
- CLI `WorkflowCommand` subcommands accept any stage name in the registry.

## Migration and Backwards Compatibility

- On first run where `stages.json` does not exist, `StageRegistry` seeds it with the 6 current defaults in `active` and an empty `available` list.
- Existing workflow files need no migration. They already use `[String: [String]]` with string keys.
- If a workflow references a stage name no longer in the registry, the orchestrator skips it with a warning log.
- The `Hook` enum remains in PiqleyCore as a source of default names for seeding, but nothing outside `StageRegistry` seeding references it for validation or ordering.
