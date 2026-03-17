# Plugin Architecture Design

**Date:** 2026-03-17
**Status:** Approved
**Scope:** piqley core — plugin system, pipeline orchestration, config refactor

---

## Overview

Piqley is being refactored from a monolithic Ghost-coupled tool into a generic photographer workflow engine. Platform-specific logic (Ghost CMS, 365 Project, image processing) moves into isolated subprocess plugins. Piqley core becomes a plugin runner and pipeline orchestrator.

Implementation approach: **Big Bang Refactor** on a separate git worktree/branch. The existing Ghost/365/ImageProcessing code is moved to `_migrate/` (not deleted) for reference while plugin repos are built.

---

## Section 1: Plugin Directory & Config Structure

Plugins live in `~/.config/piqley/plugins/`. Each plugin is a subfolder containing a `plugin.json` manifest and optionally a bundled binary.

```
~/.config/piqley/
├── config.json
├── plugins/
│   ├── ghost/
│   │   ├── plugin.json
│   │   ├── bin/
│   │   │   └── piqley-ghost
│   │   └── logs/
│   │       └── execution.jsonl
│   └── 365-project/
│       ├── plugin.json
│       ├── bin/
│       │   └── piqley-365
│       └── logs/
│           └── execution.jsonl
```

### plugin.json manifest

```json
{
  "name": "ghost",
  "pluginProtocolVersion": "1",
  "secrets": ["api-key"],
  "hooks": {
    "publish": {
      "command": "./bin/piqley-ghost",
      "args": ["publish", "$PIQLEY_FOLDER_PATH"],
      "timeout": 30,
      "protocol": "json",
      "successCodes": [],
      "warningCodes": [],
      "criticalCodes": []
    },
    "schedule": {
      "command": "./bin/piqley-ghost",
      "args": ["schedule", "$PIQLEY_FOLDER_PATH"],
      "timeout": 30,
      "protocol": "json"
    }
  }
}
```

**Fields:**
- `name` — plugin slug, must match folder name
- `pluginProtocolVersion` — protocol contract version piqley uses to determine communication shape
- `secrets` — list of secret keys the plugin needs; piqley fetches them from Keychain under `piqley.plugins.<name>.<key>`
- `hooks` — map of hook name to hook config
- `command` — relative (to plugin dir) or absolute path to executable
- `args` — argument list; supports `$PIQLEY_*` token substitution
- `timeout` — inactivity timeout in seconds (default: 30); resets on any stdout/stderr output
- `protocol` — `"json"` (default) or `"pipe"`
- `successCodes`, `warningCodes`, `criticalCodes` — exit code arrays; empty arrays default to Unix convention (0 = success, non-zero = critical)

**Command resolution:**
- Relative paths resolve against the plugin directory
- Absolute paths used as-is
- No `$PATH` resolution — use absolute paths for external tools

---

## Section 2: Plugin Communication Protocol

Plugins are isolated subprocesses. Images are never serialized — only paths are passed. Two protocol modes:

### json protocol (default)

**Piqley → Plugin (stdin):** Single JSON object written at process start.

```json
{
  "hook": "publish",
  "folderPath": "/tmp/piqley-abc123/",
  "pluginConfig": {
    "url": "https://mysite.com",
    "timezone": "America/Toronto"
  },
  "secrets": {
    "api-key": "id:secret"
  },
  "executionLogPath": "~/.config/piqley/plugins/ghost/logs/execution.jsonl",
  "dryRun": false
}
```

**Plugin → Piqley (stdout):** One JSON object per line, streamed during execution.

Progress lines (optional, resets inactivity timeout):
```json
{"type": "progress", "message": "Uploading photo.jpg..."}
```

Per-image result lines (one per image processed):
```json
{"type": "imageResult", "filename": "photo.jpg", "success": true}
{"type": "imageResult", "filename": "photo2.jpg", "success": false, "error": "Upload failed"}
```

Final result line (required, last line):
```json
{"type": "result", "success": true, "error": null}
```

**Stderr:** Captured and logged by piqley. Never forwarded directly to user output.

**Invalid stdout JSON:** Treated as a critical failure.

### pipe protocol

For plugins that don't conform to the piqley JSON spec. Piqley passes context via:

- **Environment variables:** `PIQLEY_FOLDER_PATH`, `PIQLEY_IMAGE_PATH` (batchProxy), `PIQLEY_HOOK`, `PIQLEY_DRY_RUN`, `PIQLEY_EXECUTION_LOG_PATH`, `PIQLEY_SECRET_<UPPERCASE_KEY>`
- **Token substitution in `args`:** `$PIQLEY_FOLDER_PATH`, `$PIQLEY_IMAGE_PATH`, `$PIQLEY_SECRET_API_KEY`, etc.

stdout/stderr forwarded directly to piqley's output. Exit code determines success/failure. Batch treated as atomic (all images succeed or all fail).

### batchProxy mode

For plugins that can't handle folder batches. Declared in the hook config:

```json
"pre-process": {
  "command": "/usr/local/bin/single-image-tool",
  "args": ["$PIQLEY_IMAGE_PATH"],
  "timeout": 30,
  "protocol": "pipe",
  "batchProxy": {
    "sort": {
      "key": "exif:DateTimeOriginal",
      "order": "ascending"
    }
  }
}
```

When `batchProxy` is present, piqley iterates images in the temp folder and invokes the plugin once per image. Sort keys: `filename` (alphabetical) or any EXIF/IPTC tag using `exif:<tag>` / `iptc:<tag>` notation. Order: `ascending` or `descending`.

---

## Section 3: Pipeline Execution Model

### Hook execution order

```
pre-process → post-process → publish → schedule → post-publish
```

### Startup

1. Load `config.json`
2. If `autoDiscoverPlugins: true`: scan `~/.config/piqley/plugins/`, append newly discovered plugin names to relevant pipeline hook lists (non-required, end of list); skip any in `disabledPlugins`
3. Validate all pipeline-referenced plugins exist and manifests are readable
4. Copy all source images to temp folder (`/tmp/piqley-<uuid>/`)

### Per-hook execution

For each plugin in the hook's pipeline list (in order):
1. If plugin is in the per-run blocklist — skip
2. Check all declared secrets exist in Keychain; if missing — treat as critical failure
3. Spawn subprocess
4. Stream stdout: log `progress` lines; collect `imageResult` lines; await `result` line (json protocol) or watch exit (pipe protocol)
5. Inactivity timeout: kill process, treat as critical failure if no stdout/stderr received within timeout window
6. Evaluate exit code against `successCodes`, `warningCodes`, `criticalCodes`
7. On critical failure: add plugin to per-run blocklist; abort pipeline for current run immediately
8. On warning: log warning, continue

### Per-run blocklist

In-memory only, scoped to current run. A plugin that fails any hook is blocklisted and skipped for all subsequent hooks in that run.

### Teardown

- Delete temp folder (always, success or failure)
- If `--delete-source-images` and run succeeded: delete source image files
- If `--delete-source-folder` and run succeeded: delete source folder recursively
- Both flags are no-ops on failure or `--dry-run`

### Deduplication

Piqley core has no cache. Each plugin is responsible for its own deduplication via its execution log at `~/.config/piqley/plugins/<name>/logs/execution.jsonl`. Piqley passes the log path in the stdin payload / env var; the plugin reads and writes it freely.

---

## Section 4: Core Piqley After Refactor

### Kept in core

- CLI framework (`process`, `setup`, `verify`, `clear-cache`, `secret` commands)
- Image scanning (find `.jpg`, `.jpeg`, `.jxl` files in source folder)
- Temp folder lifecycle (create, copy all source images, delete on teardown)
- Plugin runner (discover, load manifests, spawn subprocesses, handle protocols, timeouts, blocklist, exit code evaluation)
- Secrets proxy (Keychain access namespaced by plugin slug)
- Process lock (prevent concurrent runs)
- Swift-log based logging to stdout/stderr and system logs
- `verify` command (GPG signature verification — standalone, not platform-specific)

### Removed from core (moved to `_migrate/` then plugin repos)

| Directory | Destination |
|---|---|
| `Sources/piqley/Ghost/` | `piqley-ghost` repo |
| `Sources/piqley/Email/` | `piqley-365` repo |
| `Sources/piqley/ImageProcessing/` | `piqley-resize`, `piqley-metadata`, `piqley-gpgsign` repos |
| `Sources/piqley/Logging/` | each plugin owns its logs |

### Bundled default plugins

Ship as separate binaries alongside piqley. Installed into `~/.config/piqley/plugins/` by the `setup` command.

| Plugin | Hook | Seeded in pipeline by default |
|---|---|---|
| `piqley-resize` | `post-process` | yes |
| `piqley-metadata` | `post-process` | yes |
| `piqley-gpgsign` | `post-process` | no |

Third-party plugins (`piqley-ghost`, `piqley-365`, etc.) are separate repos installed manually by the user.

**Image processing notes:**
- `piqley-resize` and `piqley-metadata` can be separate steps without quality loss: resize = one lossy encode; metadata allowlist uses `CGImageDestinationCopyImageSource` (no pixel re-encode)
- `piqley-gpgsign` embeds XMP signature metadata without re-encoding pixel data

---

## Section 5: Plugin Execution Logs

Each plugin manages its own execution log at `~/.config/piqley/plugins/<name>/logs/execution.jsonl`. Piqley passes the path but never reads or writes it. Plugins use this for deduplication across runs.

Piqley core has no cache log.

---

## Section 6: Config Schema

Full `~/.config/piqley/config.json` shape:

```json
{
  "autoDiscoverPlugins": true,
  "disabledPlugins": [],
  "pipeline": {
    "pre-process":  ["piqley-metadata", "piqley-resize"],
    "post-process": [],
    "publish":      [],
    "schedule":     [],
    "post-publish": []
  },
  "plugins": {
    "piqley-resize": {
      "maxLongEdge": 2048,
      "quality": 85
    },
    "piqley-metadata": {
      "allowlist": {
        "exif": ["Make", "Model", "LensModel"],
        "iptc": ["ObjectName", "CaptionAbstract", "Keywords"]
      }
    }
  }
}
```

**Top-level fields:**
- `autoDiscoverPlugins` — default `true`; set to `false` to disable auto-appending newly discovered plugins
- `disabledPlugins` — plugin names to skip during discovery and execution, even if present on disk
- `pipeline` — ordered list of plugin names per hook; criticality determined entirely by exit codes in `plugin.json`
- `plugins` — per-plugin user configuration passed to plugin via `pluginConfig` in stdin payload

**Secrets** are stored in macOS Keychain under `piqley.plugins.<name>.<key>`. Managed via `piqley secret set/delete`.

---

## Section 7: Updated CLI

### Commands

```
piqley process <folder>           # main pipeline run
  --dry-run
  --delete-source-images          # delete source image files on success
  --delete-source-folder          # delete source folder on success (implies --delete-source-images)

piqley setup                      # seeds config, installs bundled plugins
piqley verify <image>             # GPG signature verification (unchanged)

piqley clear-cache                # clears all plugin execution logs
piqley clear-cache --plugin <name> # clears one plugin's execution log

piqley secret set <plugin> <key>  # prompts for value, stores in Keychain
piqley secret delete <plugin> <key>
```

### Removed

- All Ghost-specific and 365-specific flags
- All results file flags (`--no-results-file`, `--json-results`, `--results-dir`, `--verbose-results`)

Output is stdout/stderr only. Structured logging via swift-log to system logs.

---

## Section 8: New Source Structure

```
Sources/piqley/
├── CLI/
│   ├── ProcessCommand.swift        # Pipeline orchestration only
│   ├── SetupCommand.swift          # Updated for new config + bundled plugin install
│   ├── VerifyCommand.swift         # Unchanged
│   ├── ClearCacheCommand.swift     # Clears plugin execution logs
│   └── SecretCommand.swift         # piqley secret set/delete
├── Config/
│   └── Config.swift                # Updated schema
├── Plugins/
│   ├── PluginManifest.swift        # Decodes plugin.json
│   ├── PluginRunner.swift          # Spawns subprocesses, json/pipe protocols
│   ├── PluginDiscovery.swift       # Scans plugins dir, auto-discovery
│   ├── PluginBlocklist.swift       # In-memory per-run blocklist
│   └── ExitCodeEvaluator.swift     # Evaluates exit codes against plugin config
├── Pipeline/
│   ├── PipelineOrchestrator.swift  # Hook ordering, plugin dispatch
│   └── TempFolder.swift            # Create, copy sources, teardown
├── Secrets/
│   └── SecretStore.swift           # Namespaced plugin secret access
└── Piqley.swift                    # Entry point

_migrate/                           # Moved out of Sources, pending migration to plugin repos
├── Ghost/                          # → piqley-ghost repo
├── Email/                          # → piqley-365 repo
├── ImageProcessing/                # → piqley-resize, piqley-metadata, piqley-gpgsign repos
└── Logging/                        # → each plugin owns its logs
```
