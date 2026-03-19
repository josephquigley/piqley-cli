# SDK Build & Packaging Design

**Date:** 2026-03-18
**Status:** Draft

## Overview

Add a build/package feature to each language SDK that programmatically generates `manifest.json` and `config.json` from builder APIs, then packages the binary (or scripts/assets) into a `.piqleyplugin` file that the piqley CLI can install.

The design is **schema-first**: JSON Schema files in `piqley-plugin-sdk/schemas/` are the canonical specification. Each SDK validates against them. Third-party SDK authors can use the schemas directly without depending on any official SDK.

## Package Format

A `.piqleyplugin` file is a zip archive:

```
<plugin-name>/
├── manifest.json       # Plugin metadata, hooks, config schema
├── config.json         # Default config values and rules
├── bin/                # Executables, scripts, and runtime deps
│   └── (anything the plugin needs to run)
└── data/               # Bundled assets, templates, etc.
    └── (optional)
```

- Hook commands use relative paths: `"command": "./bin/my-plugin"`
- `logs/` is not packaged — created at runtime by piqley
- `bin/` is opaque — developers put whatever they need in there (binaries, scripts, shared libraries, `node_modules/`, etc.)
- `data/` is created at install time even if the package contains none (consistent with existing `PluginDiscovery` behavior)
- The installer must set the executable bit (`chmod +x`) on files in `bin/` after extraction, as zip archives may not preserve POSIX permissions

## JSON Schema Files

Located at `piqley-plugin-sdk/schemas/`:

```
schemas/
├── manifest.schema.json
├── config.schema.json
├── build-manifest.schema.json
├── plugin-input.schema.json
└── plugin-output.schema.json
```

- Standard JSON Schema (draft 2020-12)
- Canonical specification for valid `manifest.json`, `config.json`, `piqley-build-manifest.json`, and the plugin I/O protocol
- `plugin-input.schema.json` — defines the JSON object sent to plugins on stdin (hook, folderPath, pluginConfig, secrets, etc.)
- `plugin-output.schema.json` — defines a single output line (not the whole stream). Each newline-delimited JSON line is validated independently. Covers `progress`, `imageResult`, and `result` line types.
- `pluginProtocolVersion` is constrained to `"1"` via `const` — updated in future SDK releases when protocol evolves
- `pluginProtocolVersion` also governs the package format — any changes to the `.piqleyplugin` structure require a protocol version bump
- PiqleyCore's Swift types model the same structure but are not generated from the schema — conformance is verified by tests
- Schema files are versioned alongside the SDK
- Each language SDK bundles the schema files into its package (e.g. as Swift package resources, Python package data, npm files, Go embed) so the build CLI can locate them at runtime without network access

## Build Manifest

Each plugin project contains `piqley-build-manifest.json` at the project root:

```json
{
  "pluginName": "my-plugin",
  "pluginProtocolVersion": "1",
  "bin": [
    ".build/release/my-plugin"
  ],
  "data": [
    "resources/templates"
  ],
  "dependencies": [
    {
      "url": "https://example.com/releases/v1.0.0/other-plugin.piqleyplugin",
      "version": { "from": "1.0.0", "rule": "exact" }
    }
  ]
}
```

- `pluginName` — must match `manifest.json`'s `name` field
- `pluginProtocolVersion` — determines which schema version the build CLI validates against
- `bin` — array of paths to copy into `bin/`. Files copied directly, directories copied recursively.
- `data` — same behavior, copied into `data/`. Can be empty array.
- `dependencies` — array of plugin dependencies resolved at install time. See [Dependency Resolution](#dependency-resolution).
- Validated against `build-manifest.schema.json` before the build proceeds

### Dependency Resolution

Each dependency entry has:

- `url` — an exact URL ending in `.piqleyplugin`. The file is downloaded and its `pluginVersion` is validated against the version constraint.
- `version` — semver constraint with `from` (minimum version) and `rule`:
  - `upToNextMajor` — `>=from, <next major` (e.g. `from: "1.0.0"` accepts `1.x.x`)
  - `upToNextMinor` — `>=from, <next minor` (e.g. `from: "1.2.0"` accepts `1.2.x`)
  - `exact` — `==from`

> **Future work:** Base URL resolution (e.g. git tag discovery, `versions.json` index) can be added without breaking changes by expanding what URL formats are accepted.

**Resolution happens at install time** (`piqley plugin install`), not at build time. The build CLI embeds the dependency declarations into the package's `manifest.json` `dependencies` field. The installing CLI downloads and installs dependencies before the main plugin.

**Cycle detection:** If a dependency graph contains a cycle (A depends on B, B depends on A), the installer errors with a clear message listing the cycle.

**Duplicate handling:** If a dependency is already installed (same name and compatible version), it is skipped. If an incompatible version is already installed, the installer errors and asks the user to resolve the conflict.

### Migration: `PluginManifest.dependencies`

The existing `PluginManifest.dependencies` field in PiqleyCore is typed as `[String]?` (plain plugin name strings). This must be migrated to a structured type (e.g. `[PluginDependency]?`) to support URL and version constraint fields. The migration should maintain backward compatibility by supporting both formats during a transition period, or by bumping the protocol version.

## SDK Builder APIs

Each official SDK provides a language-idiomatic builder that produces `manifest.json` and `config.json` as files on disk. The build CLI does not invoke builder code — it consumes the already-emitted JSON files.

**Two-phase build:**

1. **Developer's responsibility:** Run the builder API (or write JSON by hand) to produce `manifest.json` and `config.json` in the project directory
2. **Build CLI's responsibility:** Read `piqley-build-manifest.json`, validate all JSON against schemas, assemble the `.piqleyplugin` zip

For languages with integrated build tooling (Swift, Go), the SDK can provide a single entry point that runs both phases. For others, the developer emits JSON first, then runs the build CLI.

**Swift:**
- Existing `buildManifest` / `buildConfig` DSLs
- Schema validation is a **test-only** dependency — not compiled into the library target
- Tests emit JSON from builders, validate against schema files

**Python:**
- Builder API (e.g. `build_manifest(name=..., hooks=...)`)
- Validates emitted JSON against schema at build time using `jsonschema`

**Node/TypeScript:**
- Builder API (e.g. `buildManifest({ name: ..., hooks: ... })`)
- Validates using `ajv` at build time

**Go:**
- Builder API (e.g. `manifest.Build(manifest.Name(...), ...)`)
- Validates using `gojsonschema` at build time

**Third-party SDKs:**
- No builder required — write JSON by hand
- Validate against schema files using any library

## Build CLI Entry Points

Each SDK provides a CLI command that reads `piqley-build-manifest.json` and produces a `.piqleyplugin` file.

### Build Steps

1. Read and validate `piqley-build-manifest.json` against `build-manifest.schema.json`
2. Read and validate `manifest.json` against `manifest.schema.json`
3. Read and validate `config.json` against `config.schema.json`
4. Verify `pluginName` matches between build manifest and `manifest.json`
5. Verify all paths in `bin` and `data` exist
6. Assemble the zip: `<plugin-name>/manifest.json`, `<plugin-name>/config.json`, `<plugin-name>/bin/...`, `<plugin-name>/data/...`
7. Write `<plugin-name>.piqleyplugin`

### Per-Language Commands

| Language | Command |
|----------|---------|
| Swift | `swift run piqley-build` |
| Python | `python -m piqley.build` |
| Node | `npx piqley-build` |
| Go | `go run <module-path>/cmd/piqley-build` |

> **Note:** The Go command path must match the actual `go.mod` module declaration in the SDK.

### Error Cases

- Missing `piqley-build-manifest.json` — error with instructions
- Schema validation failure — error listing specific violations
- Missing `bin`/`data` paths — error listing which paths don't exist
- `pluginName` mismatch — error showing both values

## CLI Install from `.piqleyplugin`

A new `InstallSubcommand` is added to `PluginCommand` (alongside existing `SetupSubcommand`, `InitSubcommand`, `CreateSubcommand`, `ConfigSubcommand`).

```
piqley plugin install ./my-plugin.piqleyplugin
```

### Install Steps

1. Open the zip, read `<plugin-name>/manifest.json`
2. Validate manifest against PiqleyCore types (which model the same structure as the schema)
3. Validate `pluginProtocolVersion` is supported by this CLI version. Supported versions are defined in `piqley-cli` as a set (initially `{"1"}`). Error message: `"Unsupported plugin protocol version '<version>'. This CLI supports versions: <supported>. Update piqley to install this plugin."`
4. Resolve and install dependencies (download `.piqleyplugin` files per dependency entries, install each recursively)
5. Check if plugin already installed — prompt to overwrite if so
6. Extract to `~/.config/piqley/plugins/<plugin-name>/`
7. Set executable permissions on files in `bin/` (`chmod +x`)
8. Create `logs/` and `data/` directories if not present
9. Run interactive setup if `config` entries require user input (same as current setup flow)

### Implementation Notes

- Add `bin` constant to `PluginDirectory` enum (alongside existing `data` and `logs`)
- `InstallSubcommand` registers under `PluginCommand`

## Skeleton Updates

Each skeleton in `piqley-plugin-sdk/Skeletons/<language>/` gets:

- `piqley-build-manifest.json` — pre-configured with language-appropriate defaults
- A build entry point source file

> **Note:** Only `Skeletons/swift/` exists today. Other language skeletons (Python, Node, Go) need to be created as part of this work or scoped separately.

### Default Build Manifests

**Swift:**
```json
{
  "pluginName": "__PLUGIN_NAME__",
  "pluginProtocolVersion": "1",
  "bin": [".build/release/__PLUGIN_NAME__"],
  "data": [],
  "dependencies": []
}
```

**Python:**
```json
{
  "pluginName": "__PLUGIN_NAME__",
  "pluginProtocolVersion": "1",
  "bin": ["src/"],
  "data": [],
  "dependencies": []
}
```

**Node:**
```json
{
  "pluginName": "__PLUGIN_NAME__",
  "pluginProtocolVersion": "1",
  "bin": ["dist/"],
  "data": [],
  "dependencies": []
}
```

**Go:**
```json
{
  "pluginName": "__PLUGIN_NAME__",
  "pluginProtocolVersion": "1",
  "bin": ["build/__PLUGIN_NAME__"],
  "data": [],
  "dependencies": []
}
```

Template substitution (`__PLUGIN_NAME__`) is handled by the existing `SkeletonFetcher`.

## Testing Strategy

### piqley-plugin-sdk (Swift)

- Add a JSON Schema validation library as a **test-only** dependency
- Tests use `buildManifest` / `buildConfig` to emit JSON
- Validate emitted JSON against `schemas/manifest.schema.json` and `schemas/config.schema.json`
- Test known-bad inputs to verify the schema rejects them
- Validate `piqley-build-manifest.json` against `schemas/build-manifest.schema.json`

### piqley-plugin-sdk (Other Languages)

- Each SDK's test suite validates builder output against the schema files
- Test cases: valid manifests, missing required fields, invalid hook names, wrong `pluginProtocolVersion`, invalid config types

### piqley-core

- No changes needed — existing Swift types continue to work
- Optionally add conformance tests that decode schema-valid JSON through PiqleyCore types to verify they agree

### piqley-cli

- Tests for `piqley plugin install` with `.piqleyplugin` files
- Test cases:
  - Valid package
  - Missing manifest
  - Invalid manifest
  - Unsupported `pluginProtocolVersion`
  - Already-installed plugin
  - Corrupted zip
  - Dependency resolution (exact URL, version constraints, cycles, duplicates)

## Scope

### In Scope

- JSON Schema files for manifest, config, and build manifest
- Build CLI entry points for Swift, Python, Node, Go
- `.piqleyplugin` package format
- `piqley plugin install` support for `.piqleyplugin` files with dependency resolution
- Skeleton updates with `piqley-build-manifest.json`
- Test suites for all of the above

### Out of Scope

- Compilation of plugin source code (left to each language's toolchain)
- Plugin registry / remote install beyond URL-based dependencies (future work)
- Signing or verification of `.piqleyplugin` files (future work)
- Creation of non-Swift skeleton directories (can be scoped separately)
