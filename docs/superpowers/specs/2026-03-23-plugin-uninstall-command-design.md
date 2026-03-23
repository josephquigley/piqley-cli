# Plugin Uninstall Command Design

## Summary

Add `piqley plugin uninstall <plugin-id>` to remove an installed plugin by its identifier. The command checks for dependency and workflow usage before deleting, removes the plugin from all pipeline configs, and deletes the plugin directory.

## Command Interface

```
piqley plugin uninstall <plugin-id> [--force]
```

- `plugin-id` (required): reverse-TLD plugin identifier (e.g., `photo.quigs.ghostcms`)
- `--force` (optional): bypasses the dependency hard-block and skips the workflow confirmation prompt. A single flag is used for simplicity since uninstall is already an intentional destructive action.

## Behavior

### 1. Validate plugin exists

Load all discovered plugins via `WorkflowCommand.loadRegistryAndPlugins()`. If the given identifier is not found among discovered plugins, check whether the directory exists on disk at `PipelineOrchestrator.defaultPluginsDirectory/{identifier}` (handles corrupted/unloadable plugins). Error if neither found.

### 2. Check for dependent plugins

Iterate every loaded workflow and call `PipelineEditor.dependents(of:in:discoveredPlugins:)` for each. Union the results into a single deduplicated list of dependent plugin identifiers across all workflows.

If dependents exist and `--force` is not set, print the list of dependent plugins and exit with an error instructing the user to pass `--force`.

If the plugin could not be loaded (corrupted), skip this step since dependency information is unavailable.

### 3. Check for workflow usage

Find all workflows whose pipeline references the plugin identifier in any stage. If the plugin appears in one or more workflows and `--force` is not set, list the affected workflows and prompt: `This plugin is used in N workflow(s): X, Y. Continue? [y/N]`

If the user declines, exit without changes.

This step runs even for corrupted plugins, since it only matches the identifier string in pipeline configs.

### 4. Delete plugin directory

Remove the entire plugin directory at `PipelineOrchestrator.defaultPluginsDirectory/{identifier}` using `FileManager.default.removeItem(at:)`.

This runs before pipeline cleanup so that if deletion fails, no workflow configs are modified.

### 5. Remove from pipeline configs

For each workflow that references the plugin, iterate all stages in the pipeline dictionary and remove the plugin identifier from each stage's list. Do not use `PipelineEditor.validateRemove()` since it throws when the plugin is absent from a stage. Instead, directly filter the plugin out of each stage list. Save the modified workflow via `WorkflowStore.save(_:)`.

### 6. Print confirmation

Print which workflows were modified and confirm the plugin was uninstalled.

## Precedence

When both dependents exist and the plugin is in workflows, the dependency check takes priority (hard block without `--force`). When `--force` is used, skip both the dependency block and the workflow confirmation prompt.

## Out of Scope

- Secret cleanup: orphaned secrets in the secret store are not removed. Can be addressed in a future cleanup command.

## Files Modified

- `Sources/piqley/CLI/PluginCommand.swift`: add `UninstallSubcommand` to subcommands array and implement the command struct

## Error Cases

- Plugin not found (not installed)
- Dependent plugins exist (without `--force`)
- User declines confirmation prompt
- File system errors during directory deletion (workflows left unmodified)
