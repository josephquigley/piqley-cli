# Workflow System Implementation Plan

Based on [2026-03-21-workflow-system-design.md](2026-03-21-workflow-system-design.md).

## Step 1: Workflow Model and WorkflowStore

**Files to create:**
- `Sources/piqley/Config/Workflow.swift` - `Workflow` struct (Codable, Sendable) with name, displayName, description, schemaVersion, pipeline fields
- `Sources/piqley/Config/WorkflowStore.swift` - stateless enum with list, load, loadAll, save, delete, clone, exists, workflowsDirectory, seedDefault

**Files to modify:**
- `Sources/piqley/Constants/PiqleyPath.swift` - add `workflows` path, remove `config` path

**Verify:** Unit-testable in isolation. WorkflowStore methods should all work against a temp directory.

## Step 2: Replace AppConfig with Workflow in Core Components

**Files to modify:**
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift` - change `config: AppConfig` to `workflow: Workflow`, update all internal references from `config.pipeline` to `workflow.pipeline`
- `Sources/piqley/Config/PipelineEditor.swift` - change `config: AppConfig` parameters to `workflow: Workflow`

**Files to delete:**
- `Sources/piqley/Config/Config.swift` - no longer needed

**Verify:** Build should succeed after updating all call sites in later steps.

## Step 3: Update ProcessCommand with Workflow Selection

**Files to modify:**
- `Sources/piqley/CLI/ProcessCommand.swift` - replace single `folderPath` arg with two optional positional args, add workflow resolution logic, load workflow via WorkflowStore

**Verify:** `piqley process ~/photos` works with 1 workflow, `piqley process ghost ~/photos` works with named workflow, proper error with 2+ workflows and no name.

## Step 4: Create WorkflowCommand Group

**Files to create:**
- `Sources/piqley/CLI/WorkflowCommand.swift` - top-level command with subcommands: edit, create, clone, delete
- `Sources/piqley/CLI/WorkflowAddPluginCommand.swift` - add-plugin subcommand (moved from ConfigCommand)
- `Sources/piqley/CLI/WorkflowRemovePluginCommand.swift` - remove-plugin subcommand (moved from ConfigCommand)

**Files to delete:**
- `Sources/piqley/CLI/ConfigCommand.swift` - replaced by WorkflowCommand
- `Sources/piqley/CLI/AddPluginCommand.swift` - moved to WorkflowAddPluginCommand
- `Sources/piqley/CLI/RemovePluginCommand.swift` - moved to WorkflowRemovePluginCommand

**Files to modify:**
- `Sources/piqley/Piqley.swift` - swap ConfigCommand for WorkflowCommand in subcommands list

## Step 5: Workflow Editor TUI

**Files to create:**
- `Sources/piqley/Wizard/WorkflowListWizard.swift` - TUI for listing workflows with CRUD (n new, Enter edit, d delete, c clone, Esc quit)

**Files to modify:**
- `Sources/piqley/Wizard/ConfigWizard.swift` - take `Workflow` instead of `AppConfig`, update save to use WorkflowStore, update title to show workflow name
- `Sources/piqley/Wizard/ConfigWizard+Plugins.swift` - update `config.pipeline` references to `workflow.pipeline`

## Step 6: Update SetupCommand

**Files to modify:**
- `Sources/piqley/CLI/SetupCommand.swift` - create workflows dir, seed default workflow, prompt for name, drop into ConfigWizard for that workflow

## Step 7: Update PluginCommand

**Files to modify:**
- `Sources/piqley/CLI/PluginCommand.swift` - `ListSubcommand` currently loads AppConfig to show pipeline status. Update to load all workflows and show which workflows each plugin appears in.

## Step 8: Build and Fix

Ensure the project compiles. Fix any remaining references to AppConfig or config.json.
