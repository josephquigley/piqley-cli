# Plugin Type Field Design Spec

## Problem

All plugins are treated uniformly after installation. There is no way to distinguish pre-compiled plugins from user-created ones. This prevents the CLI from offering mutation commands (editing manifest fields, stages, rules) on user-created plugins while protecting pre-compiled plugins from accidental modification.

## Solution

Add a required `type` field to `PluginManifest` with two values: `static` and `mutable`.

- `static`: pre-compiled or bundled plugins. Manifest and stages are immutable through CLI commands. Config values remain editable.
- `mutable`: plugins created via `piqley plugin init`. Fully mutable through CLI mutation commands.

## Data Model

### PluginType enum (PiqleyCore)

```swift
public enum PluginType: String, Codable, Sendable {
    case `static`
    case mutable
}
```

### PluginManifest changes (PiqleyCore)

Add `public let type: PluginType` as a required field. No default value, no fallback. The `pluginSchemaVersion` stays at `"1"`.

Update `CodingKeys`, `init(from:)`, `encode(to:)`, and the memberwise `init(...)` to include `type`.

### JSON representation

```json
{
  "identifier": "com.example.myplugin",
  "type": "mutable",
  "name": "My Plugin",
  ...
}
```

## Where Type Gets Set

### piqley plugin init (CLI)

Sets `"type": "mutable"` in the generated manifest.

### SDK packager (piqley-plugin-sdk)

Sets `"type": "static"` when building a `.piqleyplugin` archive. Plugin developers do not set this manually.

### Bundled plugins

Ship with `"type": "static"` in their manifests. No CLI-side override during install: the manifest's own `type` field is trusted.

## Mutation Guard

A shared guard function that mutation commands call before proceeding:

```swift
func requireMutable(_ manifest: PluginManifest) throws {
    guard manifest.type == .mutable else {
        throw ValidationError(
            "'\(manifest.name)' is a static plugin and cannot be modified. "
            + "Config values can be changed with 'piqley plugin config'."
        )
    }
}
```

### Commands that guard (reject static plugins)

- `piqley plugin rules ...` (add/edit/remove rules)
- `piqley plugin edit ...` (edit manifest fields, stages)

### Commands that do NOT guard (allowed on both types)

- `piqley plugin config` (editing runtime config values)
- `piqley plugin setup` (re-running setup)
- `piqley plugin install` / `uninstall` / `update` / `list`

## Validation

`PluginDiscovery` already validates manifests on load. The `type` field is non-optional, so `Codable` will throw automatically for manifests missing it.

No migration path: existing plugins without `type` fail to load. Users must reinstall or re-init.

## Repositories Affected

1. **piqley-core**: Add `PluginType` enum and `type` field to `PluginManifest`
2. **piqley-cli**: Set type in `InitSubcommand`, add mutation guard to `PluginRulesCommand` and `PluginCommandEditCommand`
3. **piqley-plugin-sdk**: Set `"type": "static"` in the packager
