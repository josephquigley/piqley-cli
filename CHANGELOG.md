# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

- Rules wizard now prompts for values one at a time instead of comma-separated, preventing breakage with regex patterns containing commas
- Rules editor auto-creates empty stage files when a plugin has none, instead of aborting
- Runtime errors in rules editor use ExitCode instead of ValidationError to avoid showing usage text
- Stage names in ConfigWizard plugin detail view now display in canonical pipeline order
- Rules wizard confirms with user when a target field name doesn't match any known field
- Rules wizard: Enter on empty finishes value entry after first value; Escape mid-value returns to action selection instead of proceeding to write stage

### Added

- `ForkManager` actor for COW (copy-on-write) image isolation per plugin
- `ImageConverter` for format conversion using CoreGraphics/ImageIO
- Fork/DAG-based source resolution in pipeline orchestrator
- `imageFolderOverride` parameter on `PluginRunner.run()` for fork-aware execution
- `config add-plugin` and `config remove-plugin` subcommands for non-interactive pipeline editing
- `PipelineEditor` shared validation for add/remove pipeline operations
- Skip rule effect: images matched by a skip rule are excluded from binary execution and skip records are included in the plugin wire payload
- `--overwrite-source` flag on `process` command to copy processed images back to the source directory
- Rule match negation (`not: true` on match config) inverts matching so rules fire on non-matching values
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
