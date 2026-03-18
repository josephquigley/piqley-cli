# piqley — Agent Directives

## Project

Swift CLI tool (`piqley`) for processing photos exported from Lightroom, uploading to Ghost CMS with scheduled publishing, and emailing 365 Project photos. Invoked by macOS Hazel automation.

## Design Spec

See [docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md](../docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md) for the full design.

## Key Conventions

- **Swift Package Manager** project with `swift-argument-parser`, `swift-log`, and a Swift SMTP package
- **Protocol-first for platform abstractions:** `SecretStore`, `ImageProcessor`, `MetadataReader` — macOS implementations backed by system frameworks, swappable for Linux later
- **Config at runtime:** `~/.config/piqley/config.json` is source of truth. Secrets in macOS Keychain via `SecretStore`.
- **Two-tier dedup:** local JSONL cache first (`upload-log.jsonl`, `email-log.jsonl`), Ghost API fallback on cache miss. Caches self-heal from Ghost.
- **Atomic appends** to JSONL log files (`O_APPEND`) for concurrency safety
- **Ghost Admin API:** JWT auth, Lexical JSON for post bodies, filter syntax for queue queries
- **Error handling:** per-image errors are non-fatal, fatal errors exit with code 1, partial success exits with code 2
- **Logging:** `swift-log` for structured logging throughout

## Architecture

See [architecture.md](architecture.md) for detailed guidelines. Key rules:

- **No magic strings** — all string keys, identifiers, and lookup values must live in `String`-backed enums (or enums with static properties for prefixes). See architecture.md for the full policy and enum layout.

## Code Style

- Keep files focused — one type/protocol per file
- Prefer `async/await` for Ghost API and SMTP calls
- No force unwraps in production code
- All config values should be `Codable`
