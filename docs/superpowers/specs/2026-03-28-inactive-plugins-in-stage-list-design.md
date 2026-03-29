# Inactive Plugins in Stage List

## Summary

Show available-but-not-added plugins directly in the stage plugin list as dim/italic "inactive" entries below a divider, replacing the current "N plugin(s) available to add" subtitle. Users can cursor onto inactive plugins and press Enter or `a` to add them directly.

## Current Behavior

The `pluginList` method in `ConfigWizard.swift` shows:
- Active plugins as selectable items
- A dim subtitle: "N plugin(s) available to add"
- Pressing `a` opens a separate selection screen to pick a plugin to add

## New Behavior

### Display

The item list becomes a unified list:

1. **Active plugins**: displayed as today (normal text, strikethrough if removed, red "missing" label if not on disk)
2. **Divider row**: `── inactive ──` styled dim, non-selectable
3. **Inactive plugins**: dim/italic text, sorted alphabetically. Filtered by the same logic as `availablePluginCount` (plugin supports the stage or has a workflow stage file).

The "N plugin(s) available to add" subtitle is removed since inactive plugins are now visible.

### Cursor Behavior

- Arrow keys skip the divider row automatically (cursor jumps over it)
- On an active plugin: `d` removes/undeletes, `r` reorders (unchanged)
- On an inactive plugin: Enter or `a` directly adds the plugin to the stage pipeline (appended to end), moving it from inactive to active section
- `d` and `r` are no-ops on inactive items

### Edge Cases

- **No inactive plugins**: divider and inactive section omitted entirely
- **No active plugins**: "(no plugins)" placeholder, then divider, then inactive list
- **Both empty**: just "(no plugins)" as today

## Scope

Single method change: `pluginList(stageName:)` in `ConfigWizard.swift`. The `availablePluginCount` method can be removed or left for other callers. The `addPlugin` method is still used from the `a` key when no inactive plugin is highlighted (or can be kept as a fallback).

## Files to Change

- `Sources/piqley/Wizard/ConfigWizard.swift`: `pluginList` method
