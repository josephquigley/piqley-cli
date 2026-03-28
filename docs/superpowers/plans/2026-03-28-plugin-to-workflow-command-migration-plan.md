# Plugin-to-Workflow Command Migration: Implementation Plan

**Spec:** `docs/superpowers/specs/2026-03-28-plugin-to-workflow-command-migration-design.md`

## Step 1: Move `plugin rules` to `workflow rules`

**Files:**
- `Sources/piqley/CLI/PluginRulesCommand.swift` (rename to `WorkflowRulesCommand.swift`)
- `Sources/piqley/CLI/PluginCommand.swift` (remove from subcommands)
- `Sources/piqley/CLI/WorkflowCommand.swift` (add to subcommands)

**Changes:**
1. Rename `PluginRulesCommand.swift` to `WorkflowRulesCommand.swift`
2. Rename the struct from `PluginRulesCommand` to `WorkflowRulesCommand`
3. Change `commandName` to `"rules"` (same)
4. Update abstract to `"Interactively edit rules for a plugin within a workflow."`  (same, already correct)
5. Update `usageHint` on line 94 from `"piqley plugin rules"` to `"piqley workflow rules"`
6. Make struct an extension on `WorkflowCommand` (i.e., `extension WorkflowCommand { struct RulesSubcommand: ParsableCommand { ... } }`)
7. Remove `PluginRulesCommand.self` from `PluginCommand.configuration.subcommands`
8. Add `RulesSubcommand.self` to `WorkflowCommand.configuration.subcommands`

**Verification:** `swift build` succeeds. `piqley workflow rules --help` shows the command. `piqley plugin rules` no longer exists.

## Step 2: Move `plugin command` to `workflow command`

**Files:**
- `Sources/piqley/CLI/PluginCommandEditCommand.swift` (rename to `WorkflowCommandEditCommand.swift`)
- `Sources/piqley/CLI/PluginCommand.swift` (remove from subcommands)
- `Sources/piqley/CLI/WorkflowCommand.swift` (add to subcommands)

**Changes:**
1. Rename `PluginCommandEditCommand.swift` to `WorkflowCommandEditCommand.swift`
2. Rename the struct from `PluginCommandEditCommand` to `WorkflowCommandEditCommand`
3. Make struct an extension on `WorkflowCommand`
4. Update `usageHint` on line 21 from `"piqley plugin command"` to `"piqley workflow command"`
5. Update error message on line 67 that references `'piqley plugin config'` to `'piqley workflow config'` or `'piqley plugin setup'`
6. Remove `PluginCommandEditCommand.self` from `PluginCommand.configuration.subcommands`
7. Add `CommandSubcommand.self` (or `WorkflowCommandEditCommand.self`) to `WorkflowCommand.configuration.subcommands`

**Verification:** `swift build` succeeds. `piqley workflow command --help` works. `piqley plugin command` no longer exists.

## Step 3: Drop `plugin config`

**Files:**
- `Sources/piqley/CLI/PluginCommand.swift`

**Changes:**
1. Remove the entire `ConfigSubcommand` struct (lines 458-479)
2. Remove `ConfigSubcommand.self` from `PluginCommand.configuration.subcommands`

**Verification:** `swift build` succeeds. `piqley plugin config` no longer exists.

## Step 4: Scan workflow rules directories for new stages

**Files:**
- `Sources/piqley/Wizard/ConfigWizard.swift`
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift`

### 4a: ConfigWizard stage discovery

**Changes to `ConfigWizard.swift`:**
1. Add a method that scans the workflow's rules directory for all `stage-*.json` files across all plugin subdirectories, extracts stage names, and auto-registers unknown ones via `registry.autoRegister()`
2. Call this method during `init` or at the start of `run()`
3. Modify `availablePluginCount(for:)` to also check workflow rules dirs. A plugin is available for a stage if:
   - `$0.stages.keys.contains(stageName)` (bundled), OR
   - A `stage-{stageName}.json` file exists in `WorkflowStore.pluginRulesDirectory(workflowName: workflow.name, pluginIdentifier: $0.identifier)`

### 4b: Pipeline orchestrator stage discovery

**Changes to `PipelineOrchestrator.swift`:**
1. At the start of `run()`, before the `for stage in registry.executionOrder` loop (line 108), scan the workflow's rules directories for stage files and auto-register unknown stage names
2. Use `WorkflowStore.rulesDirectory(name: workflow.name, root: workflowsRoot)` to get the base rules dir
3. Enumerate plugin subdirectories, find `stage-*.json` files, extract stage names
4. For each unknown stage name, call `registry.autoRegister()`
5. `StageRegistry` is a struct and `autoRegister` is `mutating`. The orchestrator stores it as `let`. The scanning must happen in `ProcessCommand.swift` (between line 54 where registry is loaded and line 55 where orchestrator is constructed), so the registry is mutated before being passed in.

**Verification:** Create a stage file in a workflow's rules dir for a stage not in the registry. Confirm `piqley workflow edit` shows it. Confirm `piqley process` picks it up.

## Step 5: Update tests

**Files:**
- `Tests/piqleyTests/PluginWorkflowResolverTests.swift`

**Changes:**
1. Update all `usageHint` values from `"piqley plugin command"` to `"piqley workflow command"` (lines 38, 53, 66, 79, 94)

**Verification:** `swift test` passes.

## Step 6: Update documentation

**Files:**
- `README.md`
- `docs/getting-started.md`
- `docs/advanced-topics.md`
- `man/piqley.1`

### README.md (lines 55-56):
- Remove row: `| \`piqley plugin config <name>\` | Open a plugin's config file in your editor |`
- Change row: `| \`piqley plugin rules edit <id>\` | ... |` to `| \`piqley workflow rules [workflow] <plugin>\` | Interactive rule editor for a plugin's declarative metadata rules |`
- Add row for `piqley workflow command`: `| \`piqley workflow command [workflow] <plugin>\` | Edit binary command configuration for a plugin's stages |`

### docs/getting-started.md:
- Line 87: Change `piqley plugin rules edit com.example.my-plugin` to `piqley workflow rules com.example.my-plugin`
- Lines 125-126: Remove the `piqley plugin config my-plugin` example and its label

### docs/advanced-topics.md:
- Line 591: Change `piqley plugin rules edit my-plugin` to `piqley workflow rules my-plugin`

### man/piqley.1:
- Remove synopsis entry for `plugin config` (lines 61-62)
- Change synopsis entry for `plugin rules edit` (lines 64-65) to `workflow rules`
- Remove section `Ss plugin config plugin-name` (lines 242-252)
- Update section `Ss plugin rules edit plugin-id` (lines 253-274) to `Ss workflow rules` with updated description

**Verification:** `man ./man/piqley.1` renders correctly. Documentation examples match actual command paths.
