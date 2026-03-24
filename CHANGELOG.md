# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

- Skip-rule test no longer fails due to BinaryProbe executing the test script during pre-flight validation
- Runtime errors from valid commands no longer dump usage text; only argument/usage issues show it
- Rule edit menu handlers use correct double-optional semantics to stay in menu loop after editing fields
- Environment templates (`{{original:*}}`) now resolve correctly: the `original` namespace was missing from the state payload dependency list
- Environment templates now work even when a plugin has no manifest dependencies and rules produce no state changes
- The `read` namespace is now supported in environment templates (previously only worked in rules)
- Rules wizard now prompts for values one at a time instead of comma-separated, preventing breakage with regex patterns containing commas
- Rules editor auto-creates empty stage files when a plugin has none, instead of aborting
- Runtime errors in rules editor use ExitCode instead of ValidationError to avoid showing usage text
- Stage names in ConfigWizard plugin detail view now display in canonical pipeline order
- Rules wizard confirms with user when a target field name doesn't match any known field
- Rules wizard: Enter on empty finishes value entry after first value; Escape mid-value returns to action selection instead of proceeding to write stage
- Rules wizard: declining a new field name returns to the field prompt instead of the action selector
- Save indicator ("Saved") now appears in the footer for 2 seconds on all wizards, auto-dismisses via poll timeout instead of waiting for keypress
- Both editors clean up empty stage files on exit (even without saving); uses `StageConfig.isEffectivelyEmpty` for consistent emptiness checks
- Empty stage files are logged at debug level instead of warning in PluginDiscovery
- Extracted `StageFileManager` for shared stage file save/cleanup logic
- Rules editor now shows pre-rules and post-rules as separate slots within each stage instead of only editing pre-rules; labels use "command" instead of "binary"
- `plugin init` now seeds each stage file with an empty binary config; pipeline warns about empty commands
- `piqley plugin command <identifier>` menu-driven wizard for editing environment mappings, command, args, timeout, and fork per stage; env var editor autocompletes field names from metadata catalog and dependencies, auto-generates `PQY_NAMESPACE_FIELD` env names and `{{namespace:field}}` template values; `$VAR` names autocomplete in the args editor

### Added

- `piqley plugin rules` can now be called with zero or one argument, resolving missing workflow/plugin interactively via TUI menus
- Upstream field discovery: rules editor now discovers available fields from upstream plugins' rules files instead of scanning manifests
- Rule fields can omit the namespace prefix (bare name) or use `self:` prefix, resolving to the owning plugin's identifier at compile time
- `RuleCompilationError.unresolvedSelf` error case for `self:` prefix with nil pluginId
- Pipeline call site passes `pluginIdentifier` to `RuleEvaluator` for self namespace resolution
- `piqley workflow list` subcommand showing plugin and stage counts per workflow
- `installedPlatform` written to plugin manifest on install
- Setup scanner prints existing config values and respects `--force` flag
- Config wizard shows available plugin count per stage
- Idempotent `Terminal.restore()` prevents double-restore issues
- Default workflow seeded on startup when no workflows exist
- Rules editor discovers upstream fields from workflow rules files instead of scanning installed plugin manifests
- Save-time warning when rules reference plugin namespaces that are not declared dependencies
- Field source label in rules editor changed from "dependency plugin" to "plugin"
- Automatic config migration from old config.json sidecar to new BasePluginConfig layout at startup
- `piqley secret prune` command to remove orphaned secrets not referenced by any config or workflow
- `piqley workflow config <workflow-name> <plugin-identifier>` command with `--set` and `--set-secret` flag modes and interactive mode
- `ConfigResolver` for merging base config with workflow overrides and resolving secret aliases
- `BasePluginConfigStore` for per-plugin config persistence at `~/.config/piqley/config/`
- Workflow-scoped config overrides: `config` field on Workflow struct for per-plugin value and secret alias overrides
- `SecretStore.list()` method for enumerating all stored secret keys
- `BasePluginConfig` and `WorkflowPluginConfig` types for workflow-scoped config with secret alias indirection
- `piqley plugin uninstall <plugin-id>` command to remove installed plugins, with dependency and workflow usage checks
- `piqley plugin install` now runs config and secret setup automatically when the manifest declares them
- Install-time tests for platform filtering (unsupported platform rejection and platform directory flattening)
- Platform filtering during plugin install: rejects plugins that don't support the host platform and flattens platform-specific bin/ and data/ directories
- Rules wizard: `editAction` sub-menu for editing individual emit/write actions (type, field, negated, values/replacements/source)
- Rules wizard: editing an existing rule now routes a navigable edit menu with inline editing of field, pattern, negated flag, emit actions, and write actions
- `piqley plugin create` now sanitizes plugin names for Swift package names (e.g. "Ghost & 365 Project Publisher" becomes "ghost-365-project-publisher")
- Pipeline lifecycle hooks: `pipeline-start` runs before `pre-process` and `pipeline-finished` runs after `post-publish` (best-effort, even on partial failure)
- Pipeline run ID (UUID) generated per pipeline run, passed to plugins via `pipelineRunId` in JSON payload and `PIQLEY_PIPELINE_RUN_ID` environment variable
- New workflows automatically include `pipeline-start` and `pipeline-finished` stages
- Named workflow system: replace single config.json pipeline with multiple named workflows stored in `~/.config/piqley/workflows/`
- `piqley workflow edit [name]` command with TUI for browsing and managing workflows
- `piqley workflow create [name]`, `clone`, `delete`, `add-plugin`, `remove-plugin`, `open` subcommands
- Automatic workflow selection in `piqley process`: uses the only workflow when one exists, requires explicit name when multiple exist
- BinaryProbe utility that detects whether a plugin binary is a piqley SDK plugin or a regular CLI tool via `--piqley-info` probe
- Command wizard auto-configures protocol (JSON/pipe) and batch mode based on binary detection results
- Pre-flight binary validation in pipeline orchestrator catches missing, non-executable, or protocol-mismatched binaries before any images are processed
- `ForkManager` actor for COW (copy-on-write) image isolation per plugin
- `ImageConverter` for format conversion using CoreGraphics/ImageIO
- Fork/DAG-based source resolution in pipeline orchestrator
- `imageFolderOverride` parameter on `PluginRunner.run()` for fork-aware execution
- `config add-plugin` and `config remove-plugin` subcommands for non-interactive pipeline editing
- `PipelineEditor` shared validation for add/remove pipeline operations
- Skip rule effect: images matched by a skip rule are excluded from binary execution and skip records are included in the plugin wire payload
- `--overwrite-source` flag on `process` command to copy processed images back to the source directory
- Rule match negation (`not: true` on match config) inverts matching so rules fire on non-matching values
- `formatEmitAction(_ emit: EmitConfig) -> String` method in RulesWizard+UI for formatting individual emit actions in the edit menu
- Emit negation (`not: true` on remove/removeField) inverts filtering: remove keeps only matching values, removeField keeps only the named field
- `writeBack` emit action compiled and forwarded to MetadataBuffer
- Image format support expanded: png, tiff, tif, heic, heif, webp now recognized alongside jpg, jpeg, jxl
- Unsupported file warnings logged when non-image files are found in source directory
- Pipeline exits early with error when no supported image files are found
- `piqley config edit` - interactive TUI wizard for editing the pipeline configuration
- `piqley config open` - open config file in editor (replaces `piqley config`)
- Filterable plugin browser in config editor with per-plugin action menu
- Missing plugin detection in config editor
- Config editor only offers stages a plugin has a stage config for

- `piqley plugin list` — show all installed plugins with active/inactive status, version, and stages
- `piqley plugin rules edit <plugin-id>` — ANSI-based TUI wizard for creating, editing, removing, and reordering declarative metadata rules
- Rule editor: interactive reorder mode with context-aware delete/undelete
- Rule editor: save shortcut (`s`) and save-without-quit workflow
- Rule editor: Escape means done on action selection; unsaved-changes prompt on exit
- Rule editor: autocomplete for target field in action configuration
- Rule editor: Ctrl+L opens filterable field selection list from target field prompt
- Rule editor: show match context on action selection screen
- Rule editor: show replacement patterns in rule list display
- `FieldDiscovery` for rule editor field introspection
- Environment template resolution for binary plugins
- Clone evaluation logic in `RuleEvaluator`
- Clone case to `EmitAction` enum with compilation validation
- `skip` action support in `EmitAction` and `RuleEvaluator` compilation
- `RuleEvaluationResult` struct: `evaluate()` now returns namespace and skip status
- Skip evaluation halts rule processing and writes skip records to `StateStore`
- `"skip"` as a rule match field resolves whether the current image was previously skipped
- `StateStore.appendSkipRecord` for recording skip events per image
- Fail-fast manifest validation at plugin discovery
- `piqley plugin create` command with skeleton fetcher, template substitution, and SDK version resolution
- `SemVer` parsing with compatibility matching
- Config commands to open config files in `$EDITOR`
- Interactive mode for `piqley plugin init` with description field and `$EDITOR` support
- Stage file generation for publish and post-publish on plugin init
- `_comment` fields and cross-hook examples in plugin init
- `UninstallCommand` and `InstallCommandTests`
- Read/write metadata actions
- Stage-based plugin discovery, orchestrator rework, and identifier migration
- `MetadataBuffer.invalidateAll()` for post-binary cache invalidation
- `--delete-source-contents` flag to delete source folder contents after a successful run
- `--delete-source-folder` flag to delete the source folder after a successful run
- `--non-interactive` flag to skip interactive prompts and drop invalid rules with warnings
- Swift-based CLI with process, setup, and clear-cache subcommands
- Version flag (`--version`) support
- Comprehensive man page
- Dry run mode for process command
- JSON-based configuration with file loading and saving
- Tag blocklist with glob and regex pattern matching
- Configurable required tags
- EXIF and IPTC metadata extraction via CoreGraphics
- Opt-in EXIF metadata allowlist for privacy-safe uploads
- JSONL-based execution logs for idempotent processing
- Process lock for single-instance enforcement
- Keychain-based secret storage for API keys and plugin credentials
- Interactive setup command with config creation and Keychain storage
- Homebrew formula with bottle support and GitHub Actions CI

### Changed

- All JSON encoding/decoding now uses `JSONEncoder.piqley`/`JSONDecoder.piqley` from PiqleyCore instead of bare initializers
- Bump piqley-plugin-sdk to 0.9.1 (piqley-core 0.7.2)
- Workflows are now stored as directories (`{name}/workflow.json` + `rules/` subtree) instead of flat JSON files
- Plugin rule files are stored per-workflow, making plugins immutable after install
- Stage operations (rename, duplicate, remove) are scoped to the current workflow's rules directory
- `piqley rules` command now requires a workflow context: `piqley rules [workflow] <plugin>` (falls back to sole workflow when only one exists)
- Rules are seeded from plugin built-in stage files when a plugin is first added to a workflow pipeline
- Plugin rules are cleaned up when a plugin is removed from all stages in a workflow (both TUI and CLI)
- `workflow add-plugin` seeds rules on add; `workflow remove-plugin` cleans up rules on remove
- Plugin uninstall now cleans up workflow rules directories across all workflows
- PipelineOrchestrator loads rules from workflow rules directory instead of plugin directory; plugins are immutable after install
- Pipeline runtime uses `BasePluginConfigStore` and `ConfigResolver` instead of config.json sidecar for config and secret resolution
- Plugin uninstall now deletes base config file and prunes orphaned secrets
- `PluginSetupScanner` writes `BasePluginConfig` to `~/.config/piqley/config/` instead of config.json sidecar; secrets use alias-based keys
- Test references updated from `Hook` enum to `StandardHook` for custom hooks protocol support
- Keep `pluginSchemaVersion` at `"1"` (reverted from `"2"`) since there are no production consumers
- Tests use `PluginFile` and `PluginDirectory` constants from PiqleyCore instead of magic strings
- Pipeline stages are now driven by a global `StageRegistry` (`~/.config/piqley/stages.json`) instead of the hardcoded `Hook` enum, enabling custom user-defined stages
- `PipelineOrchestrator` executes stages in flat registry order (lifecycle special-casing removed)
- `PluginDiscovery` auto-registers unknown `stage-*.json` files into the registry's available list
- `PipelineEditor` validates stage names against the registry (both active and available)
- ConfigWizard stage screen now supports add, duplicate, activate, remove, rename, and reorder operations
- `DependencyValidator` accepts explicit stage order instead of using `Hook.canonicalOrder`
- All CLI source files now reference `StageRegistry` instead of `Hook` enum for stage names and ordering
- `piqley setup` now seeds a default workflow and opens the workflow editor instead of auto-populating the pipeline
- `piqley plugin list` shows which workflows each plugin appears in instead of pipeline stages

### Removed

- `AppConfig` and `config.json`: replaced entirely by the workflow system
- `piqley config` command group: replaced by `piqley workflow`
