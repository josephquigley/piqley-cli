# Plugin Edit Command Design

**Date:** 2026-03-30
**Status:** Draft

## Summary

Add `piqley plugin edit [plugin-identifier]` to edit the default rules of mutable plugins directly in `~/.config/piqley/plugins/<id>/`. Reuses the existing `RulesWizard` TUI with a thin CLI wrapper and manifest-based field discovery.

## CLI Interface

New `EditSubcommand` registered under `PluginCommand`:

```
piqley plugin edit [plugin-identifier]
```

- **With argument:** validates the plugin exists and is mutable. Errors if the plugin is static or not found.
- **Without argument:** shows a filterable list of mutable plugins for the user to pick from.

## Plugin Selection (no argument provided)

1. Load all plugins via `PluginDiscovery.loadManifests()`.
2. Partition into mutable and static lists.
3. If no mutable plugins exist, print an error message and exit.
4. Present mutable plugins using `terminal.selectFromFilterableList()`.
5. Display footer message: `"(X unmodifiable plugins not shown. Use the workflow rules editor to adjust their default behavior.)"` where X is the count of static plugins.

## Field Discovery and Context Building

Field discovery uses manifests directly rather than the workflow-based `FieldDiscovery.discoverUpstreamFields()`, since there is no workflow context.

1. Load the selected plugin's manifest for its field definitions and declared dependencies.
2. For each declared dependency, load that dependency's manifest to get its field definitions.
3. Build `availableFields: [String: [FieldInfo]]` dictionary:
   - Plugin's own fields keyed by its identifier.
   - Dependency fields keyed by their respective identifiers.
4. Load stage configs from the plugin directory (`~/.config/piqley/plugins/<id>/stage-*.json`).
5. Construct `RuleEditingContext(availableFields:pluginIdentifier:stages:)`.

## Wizard Launch

Pass the plugin directory as `rulesDir` and launch `RulesWizard.run()`. The wizard handles the full stage selector -> pre/post slot -> rule list -> rule editor flow.

## Save Behavior

Saves write directly to the plugin's stage files in `~/.config/piqley/plugins/<id>/`. No workflow-specific post-save prompts (e.g., "add plugin to missing stages") since we are editing plugin defaults, not workflow rule overrides.

## Error Cases

- **Plugin not found:** "No plugin found with identifier '\<id\>'."
- **Plugin is static:** "\<name\> is a static plugin and cannot be modified. Config values can be changed with 'piqley plugin setup'."
- **No mutable plugins installed:** "No editable plugins installed. Create one with 'piqley plugin init'."

## Files Changed

- `Sources/piqley/CLI/PluginCommand.swift`: Add `EditSubcommand` struct, register in `subcommands` array.

No new files required. The command is a thin wrapper that composes existing components: `PluginDiscovery`, `RuleEditingContext`, `RulesWizard`, and `RawTerminal`.
