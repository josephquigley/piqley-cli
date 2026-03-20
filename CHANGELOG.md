# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- Source images are no longer overwritten by default after a successful pipeline run

### Added

- `--overwrite-source` flag on `process` command to copy processed images back to the source directory

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
