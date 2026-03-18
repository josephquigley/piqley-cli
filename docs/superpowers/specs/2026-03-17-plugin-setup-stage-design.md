# Plugin Setup Stage Design

## Overview

Plugins declare their configuration schema and optional setup commands in `manifest.json`. Piqley drives an interactive setup flow that prompts for config values, validates keychain secrets, and runs plugin setup binaries. All resolved state lives in a `config.json` sidecar per plugin.

## File Layout

```
~/.config/piqley/plugins/<plugin-name>/
├── manifest.json    # Declarative: schema, hooks, setup command (read-only)
├── config.json      # Mutable: resolved values, isSetUp flag (written by piqley)
└── setup.sh         # Optional: plugin-provided setup binary
```

## Manifest Changes

### Rename

`plugin.json` → `manifest.json` across the codebase.

### Remove `secrets` Array

The top-level `secrets` array is removed. Secret declarations move into the unified `config` array.

### New `config` Array

A unified array of config entries. Two shapes:

**Regular config entry:**
```json
{"key": "url", "type": "string", "value": null}
{"key": "quality", "type": "int", "value": 80}
{"key": "format", "type": "string", "value": "jpeg"}
```

- `key`: config field name
- `type`: value type (`string`, `int`, `float`, `bool`)
- `value`: default value, or `null` if no default (required input)
- For strings, `""` is treated the same as `null` (no useful default)

**Secret entry:**
```json
{"secret_key": "api-key", "type": "string"}
```

- `secret_key`: keychain entry name
- `type`: value type
- No `value` field — secrets are never stored on disk

### New `setup` Object (Optional)

```json
{
  "setup": {
    "command": "./setup.sh",
    "args": ["$PIQLEY_SECRET_API_KEY", "$url"]
  }
}
```

- `command`: executable path (same resolution rules as hooks — relative to plugin dir)
- `args`: argument list with env/arg substitution (secrets as `$PIQLEY_SECRET_*`, config values by key name)

### Full Manifest Example

```json
{
  "name": "piqley-ghost",
  "pluginProtocolVersion": "1",
  "config": [
    {"key": "url", "type": "string", "value": null},
    {"key": "quality", "type": "int", "value": 80},
    {"secret_key": "api-key", "type": "string"}
  ],
  "setup": {
    "command": "./setup.sh",
    "args": ["$PIQLEY_SECRET_API_KEY"]
  },
  "hooks": {
    "publish": {
      "command": "./publish.sh",
      "args": ["$PIQLEY_FOLDER_PATH"],
      "protocol": "json"
    }
  }
}
```

## Config Sidecar (`config.json`)

Written and managed by piqley. Never edited by plugins directly.

```json
{
  "values": {
    "url": "https://myblog.com",
    "quality": 80
  },
  "isSetUp": true
}
```

- `values`: resolved config values keyed by `key` from manifest. Secrets are excluded — they live in keychain only.
- `isSetUp`: present only when manifest has a `setup` object. `true` after setup binary exits 0.

## Setup Scan Logic

Triggered by:
- `piqley plugin setup` (explicit, all plugins or a named plugin)
- `piqley setup` (after bundled plugin install)
- Auto-discovery of new plugins

### Per-Plugin Flow

1. **Load `manifest.json`**
2. **Load `config.json`** if it exists (empty state otherwise)
3. **Config value resolution** — for each config entry with `key`/`value`:
   - If `values[key]` already exists in `config.json` → skip
   - If manifest `value` is non-null and non-empty-string → prompt with default: `[plugin] quality [80]: `
   - If manifest `value` is null or `""` → prompt, require input: `[plugin] url: `
   - Write resolved value to `config.json`
4. **Secret validation** — for each config entry with `secret_key`:
   - Check keychain for existing value
   - If missing → prompt user, store in keychain via existing `SecretStore`
   - Store `pluginProtocolVersion` in keychain for the plugin
5. **Setup binary** — if `setup` object exists and `isSetUp != true` in `config.json`:
   - Build environment: secrets as `PIQLEY_SECRET_*`, config values available for arg substitution
   - Run setup command
   - If exit 0 → set `isSetUp: true` in `config.json`
   - If non-zero → log error, leave `isSetUp` unset

### Prompt Format

```
[piqley-ghost] url: _
[piqley-ghost] quality [80]: _
[piqley-ghost] api-key (secret): _
```

## Integration Changes

### `PluginManifest` Model

- Remove `secrets: [String]` field
- Add `config: [ConfigEntry]` — tagged enum or struct handling both `key`/`value` and `secret_key` shapes
- Add `setup: SetupConfig?` — struct with `command` and `args`

### `PluginRunner` Secret Fetching

Currently reads from `manifest.secrets`. Changes to derive the secret list from config entries with `secret_key`. Environment variable naming unchanged (`PIQLEY_SECRET_*`).

### `PluginRunner` Config Passing

Currently receives `pluginConfig` from piqley's central `config.json`. Changes to read from the plugin's own `config.json` sidecar `values`.

### `AppConfig` Cleanup

Remove `plugins: [String: [String: JSONValue]]` dictionary — plugin config now lives in each plugin's sidecar.

### `SetupCommand`

Keeps auto-discover question and bundled plugin install. After installing, runs setup scan for all discovered plugins.

### New `piqley plugin setup` Command

Runs setup scan on demand. Optionally accepts a plugin name to set up a single plugin.

### File Reference Updates

All references to `plugin.json` become `manifest.json`:
- `PipelineOrchestrator.loadPlugin`
- `PluginDiscovery`
- Tests
