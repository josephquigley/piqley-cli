# Inactive Plugins in `workflow rules`

**Date:** 2026-03-29
**Status:** Approved

## Problem

When a user installs plugins and runs `piqley workflow rules`, the plugin selection list only shows plugins already in the workflow's pipeline. Installed-but-not-in-pipeline plugins are invisible. The user must first add the plugin via `workflow edit` or `workflow add-plugin` before they can edit its rules.

## Solution

Extend `PluginWorkflowResolver` to optionally show inactive (installed but not in pipeline) plugins in its interactive selection list. When an inactive plugin is selected in `workflow rules`, prompt the user to pick a stage, add the plugin to the workflow's pipeline, seed its rules, and proceed to the rule editor.

## Design

### PluginWorkflowResolver

Add an optional `discoveredPlugins: [LoadedPlugin]` parameter (default `[]`).

When non-empty and the resolver enters interactive plugin selection, the list is built as:

1. Pipeline plugins (sorted, as today)
2. `── inactive ──` divider (non-selectable, skipped by cursor navigation)
3. Installed plugins not in the pipeline (sorted, dim/italic, same style as ConfigWizard)

The divider uses the same skip logic already in `ConfigWizard.navigateCursor`.

**Return type** changes from `(workflowName, pluginID)` to include a third field: `isInactive: Bool`. This tells the caller whether the plugin needs pipeline activation.

When the user passes the plugin ID as an explicit CLI argument (non-interactive path), `isInactive` is derived from whether the plugin is in the pipeline. The resolver no longer throws for inactive plugins when `discoveredPlugins` is provided.

### RulesSubcommand

When `isInactive` is true, before opening the rule editor:

1. Load the plugin's manifest to get its supported stages.
2. Filter to stages active in the registry (intersection of plugin stages and `registry.executionOrder`).
3. If one matching stage: auto-select it.
4. If multiple matching stages: show a selection list ("Add to which stage?") via `RawTerminal.selectFromList`.
5. Add the plugin to `workflow.pipeline[selectedStage]`.
6. Save the workflow with `WorkflowStore.save`.
7. Seed rules with `WorkflowStore.seedRules`.
8. Remove the existing pipeline membership guard (currently throws for non-pipeline plugins). Replace with this activation flow when `isInactive` is true.
9. Proceed to rule editing as normal.

### Out of Scope

- `workflow command` does not get this behavior yet. It keeps using the resolver without `discoveredPlugins`. Can opt in later with the same mechanism.
- No changes to ConfigWizard or its existing inactive plugin display.
- No multi-stage selection. The user adds to one stage per invocation.
