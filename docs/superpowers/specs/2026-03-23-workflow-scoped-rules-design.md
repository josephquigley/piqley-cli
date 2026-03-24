# Workflow-Scoped Rules and Plugin Immutability Design

## Summary

Move rule storage from plugin directories to workflow directories, making plugins immutable after install. Each workflow owns its rules, stage operations are workflow-scoped, and a "default" workflow is seeded on fresh installs.

This is a CLI-only change spanning piqley-cli and piqley-core (read paths). The plugin SDK is unaffected.

## Directory Layout

```
~/.piqley/
  plugins/{pluginID}/              # IMMUTABLE after install
    manifest.json
    stage-{hook}.json              # Built-in rules (seed templates only, never read at runtime)
    bin/
    data/
    logs/
  config/{pluginID}.json           # BasePluginConfig (unchanged)
  workflows/
    {workflow-name}/
      workflow.json                # Pipeline, config overrides (formerly {name}.json)
      rules/
        {pluginID}/
          stage-{hook}.json        # Workflow-owned rules
  stages/stages.json               # Global stage registry (catalog of known stages)
```

### Key structural change

Workflows move from a flat file (`{name}.json`) to a directory (`{name}/`) containing `workflow.json` and a `rules/` subtree. `WorkflowStore` must be updated to handle this layout.

## Rule Seeding

When a plugin is first added to any stage in a workflow's pipeline (via ConfigWizard):

1. Copy all of the plugin's `stage-*.json` files from `plugins/{pluginID}/` into `workflows/{workflow}/rules/{pluginID}/`
2. Only stages that ship with the plugin are copied. If a plugin has no stage files, the rules directory for that plugin is created empty.
3. Seeding happens once per plugin per workflow. If the plugin already has a `rules/{pluginID}/` directory in the workflow, skip seeding (preserve existing customizations).

The plugin's built-in stage files serve as seed templates. After seeding, the workflow's copy is the sole source of truth. The plugin directory is never read for rules at runtime.

### Re-adding a removed plugin

If a plugin was previously removed from a workflow (which deletes its `rules/{pluginID}/` directory) and is later re-added, seeding runs again from the plugin's current built-in files. Prior customizations are not recoverable.

## Rule Lifecycle Operations

### Plugin removed from workflow pipeline
- Delete `workflows/{workflow}/rules/{pluginID}/` entirely
- Remove the plugin from all stage entries in `pipeline`

### Stage removed from workflow
- Delete the pipeline key for that stage
- Delete `stage-{hook}.json` from every plugin's rules dir within that workflow

### Stage renamed in workflow
- Rename the pipeline key in this workflow only
- Rename `stage-{oldHook}.json` to `stage-{newHook}.json` in every plugin's rules dir within that workflow
- Update the global `StageRegistry` name (since stage names are global identifiers, a rename updates the catalog for all workflows)

### Stage duplicated in workflow
- Copy the pipeline entry under the new name
- Copy `stage-{sourceHook}.json` to `stage-{newHook}.json` in every plugin's rules dir within that workflow

All stage operations are scoped to the current workflow. No cross-workflow or global side effects.

## Runtime Rule Loading

### Current flow
`PluginDiscovery.loadStages(from: pluginDir)` reads `stage-*.json` from the plugin directory.

### New flow
The stage loader reads from `workflows/{workflow}/rules/{pluginID}/` instead. `PipelineOrchestrator` derives the workflow rules path from the workflow name (e.g., `workflowsDirectory/{workflow.name}/rules/{pluginID}/`) and passes it to the loader.

The `PluginDiscovery.loadManifests()` validation that throws `noStageFiles` when no stage files exist must be relaxed. Stage files may legitimately not exist in the plugin directory if the plugin has no built-in rules. The validation should only apply during install (to verify the plugin package is well-formed), not during runtime loading.

Config resolution is unchanged: base config merged with workflow overrides from `workflow.json`.

## Plugin Immutability

After this change, only two operations write to `~/.piqley/plugins/`:
- `InstallCommand` (creates the directory)
- `PluginUninstallCommand` (deletes the directory)

Code that currently mutates plugin directories and must be redirected:

1. **RulesWizard + StageFileManager**: Write `stage-*.json` to workflow rules dir instead of plugin dir
2. **ConfigWizard+Stages**: Rename/duplicate/remove operations target workflow rules dirs only
3. **PluginRulesCommand**: Now requires a workflow context (see below)

## PluginRulesCommand Changes

The command signature changes to support workflow context:

- `piqley rules <plugin>`: If only one workflow exists, use it implicitly
- `piqley rules <workflow> <plugin>`: Explicit workflow selection
- If multiple workflows exist and no workflow argument is given, error with guidance

The first positional argument is checked against existing plugin identifiers. If it matches a plugin and only one workflow exists, the command falls back to using that workflow implicitly. Plugin identifiers take precedence over workflow names in disambiguation (plugin identifiers use reverse-domain notation, workflow names are plain strings, so collisions are unlikely).

## StageRegistry

The global `StageRegistry` (`stages/stages.json`) remains unchanged. It serves as a catalog of known stages and their default execution order. Workflows reference stages from this catalog via their `pipeline` keys. Adding or removing a stage from a workflow does not modify the global registry.

## Fresh Install Seeding

On first run, when no `~/.piqley/workflows/` directory exists:

1. Create `workflows/default/`
2. Write `workflows/default/workflow.json` with:
   - `name`: "default"
   - `displayName`: "Default"
   - `description`: "Default workflow"
   - `schemaVersion`: 1
   - `pipeline`: `{}`
   - `config`: `{}`
3. No `rules/` directory needed yet (no plugins in pipeline)

## Workflow Cloning

`WorkflowStore.clone()` must deep-copy the entire workflow directory, including the `rules/` subtree. The clone gets an independent copy of all rule files.

## Migration

No migration from the old flat-file workflow format. This is a clean break. Old `{name}.json` workflow files in `~/.piqley/workflows/` are ignored. Users start fresh with the seeded "default" workflow.

## Scope

### In scope
- Workflow directory structure (`{name}/workflow.json` + `rules/` subtree)
- `WorkflowStore` update to handle directory-based workflows
- Rule seeding on plugin-add-to-pipeline
- Rule cleanup on plugin-remove, stage-remove
- Stage rename/duplicate scoped to workflow
- `StageFileManager` writes to workflow rules dir
- `RulesWizard` reads/writes workflow rules dir
- `PluginRulesCommand` workflow resolution with single-workflow fallback
- `PluginDiscovery.loadStages` reads from workflow rules dir
- `PipelineOrchestrator` passes workflow rules path
- Fresh install "default" workflow seeding
- Remove all post-install plugin directory writes

### Out of scope
- Config/secret storage changes (handled by existing config-registry spec)
- Plugin SDK changes
- StageRegistry changes
- Migration from old workflow format
