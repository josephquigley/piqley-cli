# Implementation Plan: Config Edit Tool

**Spec:** `docs/superpowers/specs/2026-03-20-config-edit-tool-design.md`

## Steps

### Step 1: Extract shared TUI methods from RulesWizard+UI into RawTerminal extensions

Move the generic TUI methods out of the `RulesWizard` extension and into extensions on `RawTerminal` so both `ConfigWizard` and `RulesWizard` can use them.

**Files:**
- `Sources/piqley/Wizard/Terminal.swift` — add extensions with: `drawScreen`, `selectFromList`, `selectFromFilterableList`, `promptForInput`, `promptWithAutocomplete`, `confirm`, `showMessage`
- `Sources/piqley/Wizard/RulesWizard+UI.swift` — remove the extracted methods, keep `RulesWizard`-specific methods (`save`, `quit`, `promptUnsavedAndExit`, `applyDeletions`, `formatRule`, `showError`, `saveStages`)

The method signatures change from `func selectFromList(...)` on `RulesWizard` to `func selectFromList(...)` on `RawTerminal`. Call sites in `RulesWizard` change from `selectFromList(...)` to `terminal.selectFromList(...)`.

**Verification:** `swift build` succeeds. Existing tests pass.

### Step 2: Simplify AppConfig — remove autoDiscoverPlugins, disabledPlugins

**Files:**
- `Sources/piqley/Config/Config.swift` — remove `autoDiscoverPlugins`, `disabledPlugins`, `CodingKeys` enum, and custom `init(from:)`. Keep `pipeline` with default `[:]`, `configURL`, `load`, `save`, and bare `init()`.
- `Tests/piqleyTests/ConfigTests.swift` — rewrite tests for pipeline-only config.

**Verification:** `swift build` will fail (callers reference removed fields). That's expected — fixed in subsequent steps.

### Step 3: Update PluginDiscovery — remove autoAppend and disabled filtering

**Files:**
- `Sources/piqley/Plugins/PluginDiscovery.swift` — change `loadManifests(disabled:)` to `loadManifests()`, remove the `disabled` filtering guard, remove `autoAppend` method.
- `Tests/piqleyTests/PluginDiscoveryTests.swift` — remove `testDisabled`, `testAutoAppend`, `testNoDuplicates`. Update remaining test call sites from `loadManifests(disabled: [])` to `loadManifests()`.

**Verification:** Tests in PluginDiscoveryTests compile and pass.

### Step 4: Update PipelineOrchestrator — remove auto-discover block and `:` splitting

**Files:**
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift`:
  - Remove lines 20-27 (auto-discover block)
  - Line 77: change `pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry` to just `pluginEntry`
  - Same in `validateDependencies` (line 382)
- `Tests/piqleyTests/PipelineOrchestratorTests.swift` — remove `config.autoDiscoverPlugins = false` lines from all tests.

**Verification:** `swift test` passes for PipelineOrchestratorTests.

### Step 5: Update SetupCommand — remove auto-discover prompt

**Files:**
- `Sources/piqley/CLI/SetupCommand.swift`:
  - Remove lines 37-40 (auto-discover prompt and assignment)
  - Line 54: change `loadManifests(disabled: config.disabledPlugins)` to `loadManifests()`
  - After installing bundled plugins, seed the pipeline from discovered plugins: for each discovered plugin, add it to the stages it supports (similar to the old autoAppend logic, but done once at setup time into the config).

**Verification:** `swift build` succeeds.

### Step 6: Update PluginCommand — remove disabledPlugins references

**Files:**
- `Sources/piqley/CLI/PluginCommand.swift`:
  - `ListSubcommand`: remove `disabledSet`, active/inactive logic. Load the config's pipeline and show which stages each plugin appears in.
  - `SetupSubcommand`: change `loadManifests(disabled: config.disabledPlugins)` to `loadManifests()`.

**Verification:** `swift build` succeeds.

### Step 7: Restructure ConfigCommand with edit/open subcommands

**Files:**
- `Sources/piqley/CLI/ConfigCommand.swift`:
  - Make `ConfigCommand` a parent with `subcommands: [EditSubcommand.self, OpenSubcommand.self]`
  - `OpenSubcommand` gets the current `run()` body (open in editor)
  - `EditSubcommand` loads config and discovered plugins, creates and runs `ConfigWizard`

**Verification:** `swift build` succeeds (ConfigWizard doesn't exist yet, so add a stub or do step 8 first).

### Step 8: Implement ConfigWizard

**Files:**
- New file `Sources/piqley/Wizard/ConfigWizard.swift`:
  - Properties: `config: AppConfig`, `discoveredPlugins: [LoadedPlugin]`, `terminal: RawTerminal`, `modified: Bool`, `removedPlugins: Set<String>` (keyed by `"stage:pluginIdentifier"`)
  - `run()` — enter raw terminal, call `stageSelect()`, restore on exit
  - `stageSelect()` — show all 4 hooks with plugin counts, handle navigate/select/save/quit
  - `pluginList(stageName:)` — show plugins for stage, handle add/remove/reorder/save/back
  - `addPlugin(stageName:)` — filter discovered plugins not in stage, show filterable list, append selection
  - `interactiveReorder(stageName:startIndex:)` — same pattern as RulesWizard reorder but for plain strings
  - `save()` — apply removals, write config to disk
  - `promptUnsavedAndExit()` — same pattern as RulesWizard

**Verification:** `swift build` succeeds. Manual test: `swift run piqley config edit` launches the wizard.

### Step 9: Update documentation

**Files:**
- `man/piqley.1`:
  - Lines 116-126: update `config` command section to describe subcommands (`config edit`, `config open`)
  - Lines 256-269: remove `autoDiscoverPlugins` and `disabledPlugins` entries from CONFIGURATION section
  - Lines 18-19: update SYNOPSIS to show `config edit` and `config open`
  - Lines 392-394: update EXAMPLES to show `piqley config edit` and `piqley config open`
- `README.md`:
  - Line 50: update `plugin list` description (remove "active/inactive status")
  - Line 60: update `config` row to show `config edit` and `config open`
  - Lines 101-109: update pipeline JSON example to show pipeline-only config

**Verification:** `man ./man/piqley.1` renders correctly.

### Step 10: Final build and test

Run `swift build` and `swift test` to verify everything compiles and all tests pass.
