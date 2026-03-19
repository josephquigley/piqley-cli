# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

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
- Configurable required tags and scheduling filter tags
- Camera model to additional Ghost tags mapping
- Ghost API client with JWT authentication and Codable models
- Upload deduplication via local cache and API lookup
- Post scheduling with configurable time windows and timezone support
- 365-day project numbering for daily photo posts
- Lexical JSON content generation for post bodies
- Year-prefixed slug generation and feature image support
- EXIF and IPTC metadata extraction via CoreGraphics
- Image resizing with configurable max long edge and JPEG quality
- Opt-in EXIF metadata allowlist for privacy-safe uploads
- GPG-based cryptographic image signing with XMP metadata embedding
- Deterministic image hashing via `SignableContentExtractor`
- Signature verification via verify subcommand
- SMTP notification support for 365-day project posts
- JSONL-based upload and email logs for idempotent processing
- Process lock for single-instance enforcement
- Keychain-based secret storage for API keys and SMTP credentials
- Interactive setup command with config creation and Keychain storage
- Homebrew formula with bottle support and GitHub Actions CI

### Changed

- Renamed `pluginProtocolVersion` to `pluginSchemaVersion` across CLI
- Renamed `_instructions` to `_comment` in config, sanitized identifiers
- Renamed `PIQLEY_FOLDER_PATH` to `PIQLEY_IMAGE_FOLDER_PATH`
- Replaced `--delete-source-images` with `--delete-source-contents`
- Delegated emit validation to `RuleValidator.validateEmit` in `compileEmitAction`
- Removed hook filtering from `RuleEvaluator` — stage files imply the hook
- Updated CLI for `PluginDependency` type migration
- Extracted string constants into caseless enums across CLI

### Fixed

- `posix_spawn` with file actions for editor TTY attachment
- Accept any non-empty input as yes for description prompt
- Launch editor via `/bin/sh` with `/dev/tty` redirection
- Use `/dev/tty` for editor process so vi renders properly
- Ask before opening editor for description in plugin init
- Seed `pluginVersion` with `0.0.1` instead of `0.1.0` in plugin init
- Prevent infinite prompt loops with identifier migration
- Clarified Kodak example rule comment
