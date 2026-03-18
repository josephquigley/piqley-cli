# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- CLI: `--delete-source-contents` flag to delete source folder contents after a successful run
- CLI: `--delete-source-folder` flag to delete the source folder after a successful run

### Changed

- CLI: Replaced `--delete-source-images` (which only removed image files) with `--delete-source-contents` (removes all files and subdirectories)

- CLI: Swift-based command-line tool with process, setup, clear-cache, and verify subcommands
- CLI: Version flag (--version) support
- CLI: Comprehensive man page
- CLI: Dry run mode for process command
- Config: JSON-based configuration with file loading and saving
- Config: Tag blocklist with glob and regex pattern matching
- Config: Configurable required tags for all posts
- Config: Camera model to additional Ghost tags mapping
- Config: Configurable scheduling filter tags for non-365 posts
- Ghost: API client with JWT authentication and Codable models
- Ghost: Upload deduplication via local cache and API lookup
- Ghost: Post scheduling with configurable time windows and timezone support
- Ghost: 365-day project numbering for daily photo posts
- Ghost: Lexical JSON content generation for post bodies
- Ghost: Year-prefixed slug generation and feature image support
- Image Processing: EXIF and IPTC metadata extraction via CoreGraphics
- Image Processing: Image resizing with configurable max long edge and JPEG quality
- Image Processing: Opt-in EXIF metadata allowlist for privacy-safe uploads
- Image Processing: Image scanning with directory traversal
- Signing: GPG-based cryptographic image signing with XMP metadata embedding
- Signing: Deterministic image hashing via SignableContentExtractor
- Signing: Signature verification via verify subcommand
- Signing: XMP namespace derived from Ghost URL
- Signing: Interactive signing setup in setup command
- Email: SMTP notification support for 365-day project posts
- Logging: JSONL-based upload and email logs for idempotent processing
- Logging: Text and JSON output of processing results
- Infrastructure: Process lock for single-instance enforcement
- Infrastructure: Keychain-based secret storage for API keys and SMTP credentials
- Infrastructure: Interactive setup command with config creation and Keychain storage
- Infrastructure: Homebrew formula with bottle support and GitHub Actions CI
