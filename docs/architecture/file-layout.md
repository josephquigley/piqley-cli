# File layout and reference

Piqley stores all configuration, plugins, and runtime data under `~/.config/piqley/`. This document maps out every directory and file, summarizes the JSON schemas, and provides reference tables for environment variables, exit codes, and supported image formats.

## Top-level directory tree

```
~/.config/piqley/
├── workflows/                    # Named workflow configurations
│   └── <name>/
│       ├── workflow.json         # Pipeline definition and config overrides
│       └── rules/
│           └── <plugin-id>/
│               └── stage-*.json  # Per-plugin, per-stage rule files
├── plugins/                      # Installed plugins
│   └── <identifier>/
│       ├── manifest.json         # Plugin metadata and declarations
│       ├── stage-*.json          # Built-in stage configs (immutable after install)
│       ├── bin/                   # Plugin binaries
│       ├── data/                  # Plugin data files
│       └── logs/                  # Plugin logs
│           └── execution.jsonl   # Execution log for idempotent processing
├── config/                       # Base plugin configurations
│   └── <plugin-id>.json          # Values and secret aliases (flat, one file per plugin)
├── stages.json                   # Stage registry (active + available)
├── secrets.json                  # File-based secret store (non-macOS)
└── piqley.lock                   # Process lock file
```

Paths are defined in `PiqleyPath` (piqley-cli), `PluginFile`, and `PluginDirectory` (PiqleyCore).

## Plugin directory detail

Each installed plugin lives at `~/.config/piqley/plugins/<identifier>/`.

### `manifest.json`

The plugin's identity and capabilities. Written once at install time and never modified by the user. Contains the plugin identifier, display name, type, config schema, dependency declarations, consumed fields, and supported platforms and formats. See the [PluginManifest schema](#pluginmanifest) below for the full field list.

### Stage files (`stage-*.json`)

Files named `stage-<name>.json` define the plugin's default behaviour for each stage it participates in. These files are **immutable after install**: piqley never writes back to them. When a workflow needs customised rules, the stage files are copied into the workflow's `rules/` directory instead.

### `bin/`

Contains the plugin's executable binaries. Platform-specific binaries can be organized into subdirectories (e.g. `bin/macos-arm64/`). The `HookConfig.command` field in a stage file references the binary path relative to the plugin directory.

### `data/`

A working directory for plugin-specific data files. Plugins receive the absolute path to this directory as `dataPath` in the input payload and via the `PIQLEY_DATA_PATH` environment variable.

### `logs/`

Contains plugin log output. The primary file is `logs/execution.jsonl`, a newline-delimited JSON log that records which images have been processed. Plugins use this log for idempotent processing: they can skip images that were already handled in a previous run. The path is provided as `executionLogPath` in the input payload and via `PIQLEY_EXECUTION_LOG_PATH`.

## Workflow directory detail

Each named workflow lives at `~/.config/piqley/workflows/<name>/`.

### `workflow.json`

Defines the pipeline for this workflow: which plugins run at which stages, in what order, and any per-plugin config overrides. The file contains the workflow name, display name, description, schema version, a `pipeline` map (hook name to ordered plugin list), and a `config` map (plugin identifier to config/secret overrides). See the [Workflow schema](#workflow) below.

### `rules/`

The `rules/` directory holds **mutable copies** of plugin stage files, scoped to this workflow. The structure mirrors the plugin's stage files:

```
rules/<plugin-id>/stage-<name>.json
```

When you add a plugin to a workflow, piqley seeds this directory by copying the plugin's built-in stage files. From that point on, the workflow's copies are independent. You can edit them freely (via `piqley plugin edit` or the rules wizard) without affecting the plugin's originals or other workflows. If the directory already exists for a plugin, seeding is skipped to preserve your customisations.

## JSON schema summaries

### PluginManifest

Defined in `PluginManifest.swift` (PiqleyCore).

| Field | Type | Description |
|---|---|---|
| `identifier` | `String` | Reverse TLD identifier (e.g. `com.piqley.ghost`) |
| `name` | `String` | Human-readable display name |
| `type` | `String` | `"static"` (pre-compiled) or `"mutable"` (user-created) |
| `description` | `String?` | Short description of what the plugin does |
| `pluginSchemaVersion` | `String` | Schema version for manifest compatibility |
| `pluginVersion` | `String?` | Semantic version of the plugin |
| `config` | `[ConfigEntry]` | Configuration entries (values and secret aliases) |
| `setup` | `SetupConfig?` | Setup instructions for the plugin |
| `dependencies` | `[PluginDependency]?` | Plugins this one depends on |
| `fields` | `[ConsumedField]` | State fields this plugin declares it works with |
| `supportedFormats` | `[String]?` | Image formats the plugin can handle |
| `conversionFormat` | `String?` | Format the plugin converts images to |
| `supportedPlatforms` | `[String]?` | Platforms the plugin supports |

### StageConfig

Defined in `StageConfig.swift` (PiqleyCore). Each `stage-<name>.json` file decodes to this type.

| Field | Type | Description |
|---|---|---|
| `preRules` | `[Rule]?` | Rules evaluated before the binary runs |
| `binary` | `HookConfig?` | Binary execution configuration |
| `postRules` | `[Rule]?` | Rules evaluated after the binary runs |

### HookConfig

Defined in `HookConfig.swift` (PiqleyCore). The `binary` field inside a StageConfig.

| Field | Type | Description |
|---|---|---|
| `command` | `String?` | Executable path relative to the plugin directory |
| `args` | `[String]` | Command-line arguments |
| `timeout` | `Int?` | Execution timeout in seconds |
| `protocol` | `String?` | Plugin protocol (`"json"` or `"pipe"`) |
| `successCodes` | `[Int32]?` | Exit codes that mean success |
| `warningCodes` | `[Int32]?` | Exit codes that mean warning |
| `criticalCodes` | `[Int32]?` | Exit codes that mean critical failure |
| `batchProxy` | `BatchProxyConfig?` | Batch proxy configuration |
| `environment` | `{String: String}?` | Custom environment variable mappings |
| `fork` | `Bool?` | Whether to fork the process |

### Rule

Defined in `Rule.swift` (PiqleyCore).

| Field | Type | Description |
|---|---|---|
| `match` | `MatchConfig?` | Optional match condition. When nil, the rule fires unconditionally |
| `emit` | `[EmitConfig]` | Operations to perform on in-memory metadata |
| `write` | `[EmitConfig]` | Operations to write to persistent metadata |

**MatchConfig fields:**

| Field | Type | Description |
|---|---|---|
| `field` | `String` | The metadata field to match against |
| `pattern` | `String` | Regex pattern to match |
| `not` | `Bool?` | When true, inverts the match |

**EmitConfig fields:**

| Field | Type | Description |
|---|---|---|
| `action` | `String?` | `"add"`, `"remove"`, `"replace"`, `"removeField"`, `"clone"`, `"skip"`. Defaults to `"add"` |
| `field` | `String?` | Target field. Use `"*"` with `removeField`/`clone` for all fields |
| `values` | `[String]?` | Values to add or patterns to remove |
| `replacements` | `[Replacement]?` | Ordered pattern-to-replacement mappings for `"replace"` |
| `source` | `String?` | Source `namespace:field` reference for `"clone"` |
| `not` | `Bool?` | When true, inverts the emit |

### Workflow

Defined in `Workflow.swift` (piqley-cli).

| Field | Type | Description |
|---|---|---|
| `name` | `String` | Unique workflow name (also the directory name) |
| `displayName` | `String` | Human-readable name |
| `description` | `String` | Short description |
| `schemaVersion` | `Int` | Schema version, defaults to `1` |
| `pipeline` | `{String: [String]}` | Hook name to ordered list of plugin identifiers |
| `config` | `{String: WorkflowPluginConfig}` | Per-plugin config and secret overrides |

### PluginInputPayload

Defined in `PluginInputPayload.swift` (PiqleyCore). Sent to plugins as JSON on stdin when a hook is invoked.

| Field | Type | Description |
|---|---|---|
| `hook` | `String` | The hook stage being executed |
| `imageFolderPath` | `String` | Path to the image folder being processed |
| `pluginConfig` | `{String: JSONValue}` | Key-value configuration for this plugin |
| `secrets` | `{String: String}` | Resolved secret values |
| `executionLogPath` | `String` | Path to the execution log file |
| `dataPath` | `String` | Path to the plugin's data directory |
| `logPath` | `String` | Path to the plugin's log directory |
| `dryRun` | `Bool` | Whether this is a dry run (no side effects) |
| `debug` | `Bool` | Whether debug output is enabled |
| `state` | `{String: {String: {String: JSONValue}}}?` | Persisted state from previous executions |
| `pluginVersion` | `String` | Semantic version of this plugin |
| `lastExecutedVersion` | `String?` | Last version of this plugin that was executed |
| `skipped` | `[SkipRecord]` | Images that were skipped during pipeline processing |
| `pipelineRunId` | `String?` | UUID for the current pipeline run |

### PluginOutputLine

Defined in `PluginOutputLine.swift` (PiqleyCore). Plugins write these as newline-delimited JSON to stdout.

| Field | Type | Description |
|---|---|---|
| `type` | `String` | `"progress"`, `"imageResult"`, or `"result"` |
| `message` | `String?` | Human-readable message |
| `filename` | `String?` | Filename for image results |
| `success` | `Bool?` | Whether the operation succeeded (used by `"result"` lines) |
| `status` | `String?` | Image outcome (used by `"imageResult"` lines) |
| `error` | `String?` | Error message if the operation failed |
| `state` | `{String: {String: JSONValue}}?` | State to persist, keyed by folder path then key |

## Environment variable reference

These environment variables are set by piqley before invoking a plugin binary.

| Variable | Description |
|---|---|
| `PIQLEY_HOOK` | Current stage hook name |
| `PIQLEY_IMAGE_FOLDER_PATH` | Path to the working image folder |
| `PIQLEY_IMAGE_PATH` | Path to the current image being processed |
| `PIQLEY_DRY_RUN` | `"1"` or `"0"` |
| `PIQLEY_DEBUG` | `"1"` or `"0"` |
| `PIQLEY_PIPELINE_RUN_ID` | UUID for the current pipeline run |
| `PIQLEY_EXECUTION_LOG_PATH` | Path to the execution log file |
| `PIQLEY_CONFIG_<KEY>` | Config values, with the key uppercased |
| `PIQLEY_SECRET_<KEY>` | Resolved secrets, with the key uppercased |

Plugins can also declare custom environment variable mappings via the `environment` field in `HookConfig`. Each entry maps an environment variable name to a value or template string.

Note: `dataPath`, `logPath`, and `executionLogPath` are provided in the JSON payload for JSON-protocol plugins, but only `PIQLEY_EXECUTION_LOG_PATH` has an environment variable counterpart for pipe-protocol plugins.

## Exit code reference

Piqley evaluates plugin exit codes using `ExitCodeEvaluator`. Plugins can declare custom exit code mappings in their `HookConfig`; when no codes are declared, Unix defaults apply.

| Result | Default behaviour | Custom behaviour |
|---|---|---|
| **Success** | Exit code `0` | Any code listed in `successCodes` |
| **Warning** | (none) | Any code listed in `warningCodes` |
| **Critical** | Any non-zero exit code | Any code listed in `criticalCodes` |

When custom codes are configured, any exit code not present in any of the three lists is treated as critical. When all three lists are empty (or omitted), the evaluator falls back to Unix defaults: `0` is success, everything else is critical.

## Supported image formats

Piqley recognizes the following file extensions when copying images into the working folder. Extensions are matched case-insensitively.

| Extension | Format |
|---|---|
| `jpg` | JPEG |
| `jpeg` | JPEG |
| `png` | PNG |
| `tiff` | TIFF |
| `tif` | TIFF |
| `heic` | HEIC |
| `heif` | HEIF |
| `webp` | WebP |
| `jxl` | JPEG XL |

---

[Architecture overview](overview.md) | [Pipeline execution](pipeline.md) | [Plugin system](plugin-system.md) | [Rules and state](rules-and-state.md) | [Config and workflows](config-and-workflows.md) | [CLI commands](cli-commands.md)
