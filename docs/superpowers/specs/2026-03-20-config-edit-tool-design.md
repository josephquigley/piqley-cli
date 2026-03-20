# Config Edit Tool Design

**Date:** 2026-03-20

## Summary

Replace the current `piqley config` (which opens `$EDITOR`) with a TUI-based config editor that mirrors the rules wizard UX. Simultaneously simplify `AppConfig` by removing `autoDiscoverPlugins`, `disabledPlugins`, and the vestigial `:required` suffix — the pipeline dict becomes the sole source of truth for which plugins run in which stages and in what order.

## Config Simplification

### Before

```swift
struct AppConfig: Codable, Sendable {
    var autoDiscoverPlugins: Bool = true
    var disabledPlugins: [String] = []
    var pipeline: [String: [String]] = [:]
}
```

### After

```swift
struct AppConfig: Codable, Sendable {
    var pipeline: [String: [String]] = [:]
}
```

- `autoDiscoverPlugins` removed — plugins must be explicitly placed in pipeline stages.
- `disabledPlugins` removed — a plugin not in any stage's list simply doesn't run.
- `:required` suffix removed — pipeline entries are plain plugin identifiers.

## Command Structure

`ConfigCommand` becomes a parent command with subcommands:

- `piqley config edit` — launches the TUI wizard.
- `piqley config open` — opens `~/.config/piqley/config.json` in `$EDITOR` (current behavior of `piqley config`).
- `piqley config` with no subcommand shows help.

## ConfigWizard UX

### Screen 1: Stage Selector

Shows all four hooks in canonical order with plugin counts. Same pattern as `RulesWizard.stageSelect()`.

```
Edit Pipeline

  pre-process (2 plugins)
▸ post-process (1 plugin)
  publish (0 plugins)
  post-publish (0 plugins)

↑↓ navigate  ⏎ select  s save  Esc quit
```

Keybindings:
- `↑↓` — navigate stages
- `Enter` — drill into plugin list for selected stage
- `s` — save config to disk
- `Esc` — prompt if unsaved changes, then quit

### Screen 2: Plugin List (per stage)

Shows the ordered plugin list for the selected stage.

```
post-process plugins

▸ piqley-metadata
  piqley-resize

↑↓ navigate  a add  d remove  r reorder  s save  Esc back
```

Keybindings:
- `↑↓` / `PageUp` / `PageDown` — navigate
- `a` (add) — opens filterable list of discovered plugins not already in this stage; selected plugin is appended to the end
- `d` (remove) — marks plugin at cursor for removal (strikethrough until save, toggles like rules wizard deletion)
- `r` (reorder) — interactive reorder mode: selected item shown italic+indented, arrow keys move it, Enter confirms, Escape cancels
- `s` — save config to disk
- `Esc` — back to stage selector

## Implementation: ConfigWizard

New file `Sources/piqley/Wizard/ConfigWizard.swift`.

```swift
final class ConfigWizard {
    var config: AppConfig
    let discoveredPlugins: [LoadedPlugin]
    let terminal: RawTerminal
    var modified: Bool
    var removedPlugins: Set<String>  // keyed by "stage:index"
}
```

Reuses existing TUI components from `RulesWizard+UI.swift`:
- `drawScreen(title:items:cursor:footer:)` — screen rendering
- `selectFromFilterableList(title:items:)` — for the "add plugin" picker
- Interactive reorder pattern from `RulesWizard.interactiveReorder`
- Strikethrough/deletion toggle pattern from `RulesWizard.ruleList`
- Unsaved changes prompt from `RulesWizard.promptUnsavedAndExit`

The wizard receives discovered plugins from the command layer (via `PluginDiscovery.loadManifests()`), so it knows the full set of available plugins for the "add" action.

## Cleanup: Removed Code

### AppConfig (`Config.swift`)
- Remove `autoDiscoverPlugins` field, `disabledPlugins` field, `CodingKeys` enum (no longer needed with single field), and custom `init(from:)` (default Codable suffices with a default value on `pipeline`).

### PipelineOrchestrator (`PipelineOrchestrator.swift`)
- Remove the auto-discover block that calls `PluginDiscovery.autoAppend`.
- Remove the `:` splitting on plugin entries (`pluginEntry.split(separator: ":")`). Plugin entries are plain identifiers.

### PluginDiscovery (`PluginDiscovery.swift`)
- Remove `autoAppend(discovered:into:)` static method.
- Change `loadManifests(disabled:)` to `loadManifests()` — no disabled filtering.

### PluginCommand.ListSubcommand (`PluginCommand.swift`)
- Remove active/inactive status based on `disabledPlugins`.
- Show pipeline stage membership instead (which stages each plugin appears in from the loaded config).

### ConfigCommand (`ConfigCommand.swift`)
- Restructure as parent command with `EditSubcommand` and `OpenSubcommand`.

### All callers
- Update all call sites of `loadManifests(disabled:)` to `loadManifests()`.
- Remove all references to `config.disabledPlugins` and `config.autoDiscoverPlugins`.

## Tests

- Update `ConfigTests` — remove tests for `autoDiscoverPlugins` and `disabledPlugins`; verify pipeline-only config round-trips correctly.
- Update `PipelineOrchestratorTests` — remove auto-discover and disabled-plugin test scenarios; update config fixtures.
- Update `PluginDiscoveryTests` — remove tests for `autoAppend`; update `loadManifests` call sites.
- Add config wizard save/load round-trip test (config with plugins in various stages saves and loads correctly).
