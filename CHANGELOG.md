# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `piqley config edit` — interactive TUI wizard for editing the pipeline configuration
- `piqley config open` — open config file in editor (replaces `piqley config`)
- `piqley plugin list` — show all installed plugins with version and stages

### Changed

- Simplify `AppConfig` to pipeline-only (remove `autoDiscoverPlugins`, `disabledPlugins`)
- `piqley plugin list` shows pipeline stage membership instead of active/inactive status
- `piqley setup` seeds pipeline from all discovered plugins instead of hardcoded defaults

### Fixed

- Copy processed images back to source directory after successful pipeline run
- `piqley plugin rules edit <plugin-id>` — interactive TUI wizard for creating, editing, removing, and reordering declarative metadata rules
- `FieldDiscovery` for rule editor field introspection
- Environment template resolution for binary plugins
- `TermKit` dependency and `PluginRulesCommand` scaffold
- Clone evaluation logic in `RuleEvaluator`
- Clone case to `EmitAction` enum with compilation validation
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
- Swift-based CLI with process, setup, clear-cache, and verify subcommands
- Version flag (`--version`) support
- Comprehensive man page
- Dry run mode for process command
- JSON-based configuration with file loading and saving
- Tag blocklist with glob and regex pattern matching
- Configurable required tags
- EXIF and IPTC metadata extraction via CoreGraphics
- Image resizing with configurable max long edge and JPEG quality
- Opt-in EXIF metadata allowlist for privacy-safe uploads
- GPG-based cryptographic image signing with XMP metadata embedding
- Deterministic image hashing via `SignableContentExtractor`
- Signature verification via verify subcommand
- JSONL-based execution logs for idempotent processing
- Process lock for single-instance enforcement
- Keychain-based secret storage for API keys and plugin credentials
- Interactive setup command with config creation and Keychain storage
- Homebrew formula with bottle support and GitHub Actions CI
