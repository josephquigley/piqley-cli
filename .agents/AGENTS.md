# piqley — Agent Directives

## Project

Swift CLI tool (`piqley`) — a plugin-driven photographer workflow engine for processing and publishing photos. Invoked by macOS Hazel automation or any folder-watching tool.

## Design Spec

See [docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md](../docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md) for the full design.

## Key Conventions

- **Swift Package Manager** project with `swift-argument-parser` and `swift-log`
- **Protocol-first for platform abstractions:** `SecretStore`, `ImageProcessor`, `MetadataReader` — macOS implementations backed by system frameworks, swappable for Linux later
- **Config at runtime:** `~/.config/piqley/config.json` is source of truth. Secrets in macOS Keychain via `SecretStore`.
- **Plugin pipeline:** all processing, publishing, and post-processing is handled by plugins via stdin/stdout JSON protocol or pipe protocol
- **Atomic appends** to JSONL log files (`O_APPEND`) for concurrency safety
- **Error handling:** per-image errors are non-fatal, fatal errors exit with code 1, partial success exits with code 2
- **Logging:** `swift-log` for structured logging throughout

## Architecture

See [architecture.md](architecture.md) for detailed guidelines. Key rules:

- **No magic strings** — all string keys, identifiers, and lookup values must live in `String`-backed enums (or enums with static properties for prefixes). See architecture.md for the full policy and enum layout.

## Code Style

- Keep files focused — one type/protocol per file
- Prefer `async/await` for async operations
- No force unwraps in production code
- All config values should be `Codable`
