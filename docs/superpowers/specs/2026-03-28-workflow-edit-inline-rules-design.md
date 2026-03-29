# Inline Rules Editing from Workflow Edit TUI

**Date:** 2026-03-28

## Problem

`piqley workflow edit` allows drilling into stages to see the plugin list, but there is no way to edit rules from that view. Users must exit and use the separate `piqley workflow rules` command. This breaks the editing flow.

## Solution

Add Enter-to-edit-rules in the stage plugin list view of ConfigWizard. Pressing Enter on a discovered plugin launches a nested RulesWizard scoped to that stage, landing directly on the slot selector (pre-rules / post-rules). Esc returns to the plugin list.

## User-Facing Behavior

- In `ConfigWizard.pluginList(stageName:)`, pressing Enter on a plugin opens the RulesWizard for that plugin, scoped to that stage.
- The user lands on the slot selector (pre-rules / post-rules), skipping the stage selector since the stage context is already known.
- Esc from the slot selector returns to the plugin list.
- The footer updates to show the Enter key hint (e.g. `⏎ rules`) alongside existing keys.
- Only discovered plugins can be drilled into (not missing ones).
- If a plugin has no rules directory yet, one is seeded before launching.

## Technical Design

### RulesWizard Changes

Add a `runForStage(_ stageName: String)` method:
- Calls `slotSelect(stageName:)` directly, skipping the stage selector.
- On return, if there are unsaved changes, prompts save/discard/cancel via a new `promptUnsavedAndReturn()` method that returns a bool instead of calling `Foundation.exit(0)`.
- Restores its terminal via the existing `defer { terminal.restore() }`.

The existing `run()` and `quit()` methods remain unchanged for the standalone `workflow rules` command.

### RuleEditingContext Construction

When Enter is pressed on a plugin, ConfigWizard builds the RuleEditingContext using the same steps as `WorkflowRulesCommand`:

1. Look up the `LoadedPlugin` from `discoveredPlugins` (provides manifest and directory).
2. Get `rulesDir` from `WorkflowStore.pluginRulesDirectory`.
3. Load stages from rulesDir via `PluginDiscovery.loadStages`.
4. Ensure the target stage exists in the loaded stages (add empty `StageConfig` if missing).
5. Discover upstream fields via `FieldDiscovery`.
6. Build `RuleEditingContext` and create `RulesWizard`.
7. Call `wizard.runForStage(stageName)`.

This logic lives in a new private method on ConfigWizard: `editRulesForPlugin(_:inStage:)`.

### Terminal Lifecycle

RulesWizard creates its own `RawTerminal`, which enters a new alt screen buffer. When the RulesWizard finishes and restores, it exits that alt screen, returning to ConfigWizard's alt screen. ConfigWizard then redraws its plugin list naturally on the next loop iteration.

### Rules Saving

Rules save independently to the plugin's rules directory (same as the standalone command). This is orthogonal to the workflow pipeline save in ConfigWizard. The existing `promptToAddToMissingStages` logic in RulesWizard+UI.swift handles prompting the user if rules are saved for a stage the plugin isn't in the pipeline for.

## Files Changed

- **RulesWizard.swift**: add `runForStage(_ stageName:)` method.
- **RulesWizard+UI.swift**: add `promptUnsavedAndReturn()` method (returns bool instead of calling exit).
- **ConfigWizard.swift**: add Enter handler in `pluginList`, update footer text.
- **ConfigWizard+Rules.swift** (new file): `editRulesForPlugin(_:inStage:)` with context construction.
