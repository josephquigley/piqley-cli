# piqley-cli — Agent Directives

> Cross-repo conventions (code style, architecture, git commits) live in the top-level `../../.agents/AGENTS.md`. This file covers CLI-specific details only.

## Project

Swift CLI tool (`piqley`) — the main entry point for running plugin pipelines. Uses `swift-argument-parser` for CLI parsing and `swift-log` for structured logging.

## Design Spec

See [docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md](../docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md) for the full design.

## CLI-Specific Constants

These constant enums live in `Sources/piqley/Constants/` (not in PiqleyCore):

| Domain | Enum | Location |
|--------|------|----------|
| Environment variables | `PluginEnvironment` | `Sources/piqley/Constants/PluginEnvironment.swift` |
| Filesystem paths | `PiqleyPath` | `Sources/piqley/Constants/PiqleyPath.swift` |
| Plugin directories | `PluginDirectory` | `Sources/piqley/Constants/PluginDirectory.swift` |
| Secret namespacing | `SecretNamespace` | `Sources/piqley/Constants/SecretNamespace.swift` |
