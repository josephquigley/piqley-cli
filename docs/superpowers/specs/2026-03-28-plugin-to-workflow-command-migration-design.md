# Plugin-to-Workflow Command Migration

## Summary

Restructure the CLI command tree to enforce a clear boundary: `plugin` commands manage the plugin itself (install, update, uninstall, setup, init, create), while `workflow` commands manage per-workflow configuration. Commands that mutate workflow-scoped files (`plugin rules`, `plugin command`) move under `workflow`. The raw file opener `plugin config` is dropped entirely, superseded by `plugin setup` (base config) and `workflow config` (per-workflow overrides). The ConfigWizard and pipeline orchestrator are updated to discover stages from workflow rules directories.

## Motivation

The `plugin rules` and `plugin command` subcommands were created before plugins were made immutable. Both already operate on workflow-scoped rule files, not plugin files, making their placement under `plugin` misleading. `plugin config` opens a raw JSON file in an editor, which is redundant now that `plugin setup` provides an interactive TUI for base config and `workflow config` handles per-workflow overrides.

Separately, the ConfigWizard and pipeline orchestrator only discover stages from plugin install directories. Stages created via the rules editor in a workflow's rules directory are invisible to both the wizard and the pipeline runner.

## Changes

### 1. Move `plugin rules` to `workflow rules`

- Rename `PluginRulesCommand` to `WorkflowRulesCommand` (or restructure as `WorkflowCommand.RulesSubcommand`)
- Register under `WorkflowCommand.configuration.subcommands`
- Remove from `PluginCommand.configuration.subcommands`
- Workflow name remains an optional argument; if omitted, present a TUI list of available workflows
- Plugin identifier remains the second argument (prompted if omitted)
- Update `usageHint` from `"piqley plugin rules"` to `"piqley workflow rules"`

### 2. Move `plugin command` to `workflow command`

- Same treatment as `plugin rules`
- Rename `PluginCommandEditCommand` to `WorkflowCommandEditCommand` (or `WorkflowCommand.CommandSubcommand`)
- Update `usageHint` from `"piqley plugin command"` to `"piqley workflow command"`
- Update error message that previously referenced `piqley plugin config`

### 3. Drop `plugin config`

- Remove `ConfigSubcommand` from `PluginCommand` (lines 458-479 of PluginCommand.swift)
- Remove from `PluginCommand.configuration.subcommands`
- Base config is managed by `plugin setup`; per-workflow overrides by `workflow config`

### 4. Scan workflow rules directories for new stages

**ConfigWizard:** When initializing, scan all plugin rules directories under the current workflow (via `WorkflowStore.rulesDirectory`) for `stage-*.json` files with stage names not yet in the registry. Auto-register them via `registry.autoRegister()`.

**ConfigWizard.availablePluginCount:** When determining if a plugin is available for a stage, also check the workflow's rules directory for a matching `stage-{name}.json`. A plugin is available for a stage if either:
- `LoadedPlugin.stages` contains the stage name (bundled), OR
- A stage file exists in the workflow's rules directory for that plugin

**Pipeline orchestrator:** When loading for a run, scan the workflow's rules directories for stage files and auto-register unknown stage names before iterating `registry.executionOrder`. This ensures `piqley process` picks up user-created stages without requiring `workflow edit` first.

### 5. Update documentation and guides

Files requiring updates:

**User-facing docs:**
- `README.md`: Remove `plugin config` row, update `plugin rules` reference to `workflow rules`
- `docs/getting-started.md`: Update command examples (`plugin rules edit` to `workflow rules`, `plugin config` to `plugin setup` or `workflow config`)
- `docs/advanced-topics.md`: Update `plugin rules edit` reference
- `man/piqley.1`: Remove `plugin config` section, move `plugin rules` documentation to `workflow rules`, update all examples

**Historical specs and plans** (in `docs/superpowers/specs/` and `docs/superpowers/plans/`): No changes. These reflect decisions made at the time they were written.

### 6. Update tests

- Update `usageHint` strings in `PluginWorkflowResolverTests.swift` from `"piqley plugin command"` to `"piqley workflow command"`

## Files affected

| File | Change |
|------|--------|
| `Sources/piqley/CLI/PluginCommand.swift` | Remove `ConfigSubcommand`, `PluginRulesCommand`, `PluginCommandEditCommand` from subcommands |
| `Sources/piqley/CLI/PluginRulesCommand.swift` | Rename file to `WorkflowRulesCommand.swift`, register under `WorkflowCommand` |
| `Sources/piqley/CLI/PluginCommandEditCommand.swift` | Rename file to `WorkflowCommandEditCommand.swift`, register under `WorkflowCommand` |
| `Sources/piqley/CLI/WorkflowCommand.swift` | Add `RulesSubcommand`, `CommandSubcommand` to subcommands |
| `Sources/piqley/Wizard/ConfigWizard.swift` | Scan workflow rules dirs for stages; update `availablePluginCount` |
| `Sources/piqley/Pipeline/PipelineOrchestrator.swift` or `+Helpers.swift` | Scan workflow rules dirs for stages before execution |
| `Tests/piqleyTests/PluginWorkflowResolverTests.swift` | Update usage hints |
| `README.md` | Update command reference table |
| `docs/getting-started.md` | Update command examples |
| `docs/advanced-topics.md` | Update command examples |
| `man/piqley.1` | Remove `plugin config`, relocate `plugin rules` docs |

## Constraints

- All path resolution must use `PiqleyPath` constants and `WorkflowStore` methods. No hardcoded path strings.

## Out of scope

- Changing `plugin uninstall` behavior (stays as-is with cross-workflow cleanup)
- Changing `plugin setup` behavior
- Modifying `LoadedPlugin.stages` to include workflow-level stages (workflow awareness stays in the wizard and orchestrator)
- Updating historical spec/plan documents
