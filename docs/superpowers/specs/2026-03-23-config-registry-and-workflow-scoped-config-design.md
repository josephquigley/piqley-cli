# Config Registry and Workflow-Scoped Config/Secrets Design

## Summary

Replace static JSON config/secret declarations in `piqley-build-manifest.json` with a programmatic `ConfigRegistry` DSL in the SDK, and restructure config/secret storage to support workflow-scoped overrides with shared secret aliases.

This spans three repos: piqley-plugin-sdk (DSL and build tooling), piqley-core (shared types), and piqley-cli (runtime resolution, CLI commands, secret storage).

## Part 1: ConfigRegistry DSL (piqley-plugin-sdk)

### ConfigRegistry

A new `ConfigRegistry` type in `PiqleyPluginSDK`, built with a result builder. Plugin authors declare config values and secrets in the `PluginHooks` module alongside their `HookRegistry`:

```swift
public let pluginConfig = ConfigRegistry {
    Config("siteUrl", type: .string, default: "https://example.com")
    Config("outputQuality", type: .int, default: 85)
    Secret("API_KEY", type: .string)
    Secret("WEBHOOK_SECRET", type: .string)
}
```

- `Config` is a builder struct that maps to `ConfigEntry.value`
- `Secret` is a builder struct that maps to `ConfigEntry.secret`
- `ConfigRegistry` stores `[ConfigEntry]` and exposes `writeConfigEntries(to:)` which encodes them as JSON to a file named `config-entries.json`

### Builder structs

```swift
public protocol ConfigComponent: Sendable {}

public struct Config: ConfigComponent {
    let entry: ConfigEntry
    public init(_ key: String, type: ConfigValueType, default value: JSONValue) {
        self.entry = .value(key: key, type: type, value: value)
    }
}

public struct Secret: ConfigComponent {
    let entry: ConfigEntry
    public init(_ key: String, type: ConfigValueType) {
        self.entry = .secret(secretKey: key, type: type)
    }
}
```

A `@ConfigComponentBuilder` result builder collects these into the registry.

### Template changes

The `PluginHooks/Hooks.swift` template exports both symbols:

```swift
public let pluginRegistry = HookRegistry { ... }
public let pluginConfig = ConfigRegistry { ... }
```

### Build tool rename

Rename `piqley-stage-gen` to `piqley-manifest-gen` across:
- The executable target in `Package.swift` template
- The `StageGen/main.swift` source directory (rename to `ManifestGen/main.swift`)
- The build script detection and invocation

The renamed tool writes both stage files and `config-entries.json`:

```swift
try pluginRegistry.writeStageFiles(to: outputDir)
try pluginConfig.writeConfigEntries(to: outputDir)
```

### Packager changes (Swift)

The Swift `Packager` reads `config-entries.json` from the plugin directory and uses it as the config entries in `manifest.json`. The `BuildManifest.config` field is no longer used by the Swift packager.

Other language packagers (future Node, etc.) continue to read config from their own build manifest format.

### config-entries.json format

A JSON array of `ConfigEntry` objects, matching the existing encoding:

```json
[
  {"key": "siteUrl", "type": "string", "value": "https://example.com"},
  {"key": "outputQuality", "type": "int", "value": 85},
  {"secret_key": "API_KEY", "type": "string"},
  {"secret_key": "WEBHOOK_SECRET", "type": "string"}
]
```

## Part 2: Workflow-Scoped Config and Secret Storage (piqley-cli)

### Storage layout

**Base config per plugin:** `~/.config/piqley/config/<plugin-identifier>.json`

```json
{
  "values": {
    "siteUrl": "https://blog.example.com",
    "outputQuality": 85
  },
  "secrets": {
    "API_KEY": "ghost-api-key"
  }
}
```

The `values` section holds actual config values. The `secrets` section holds secret aliases: human-readable names that map to keychain entries. The actual secret values are in the keychain, keyed by the alias name.

**Workflow overrides:** added to the workflow JSON file

```json
{
  "name": "staging",
  "pipeline": { ... },
  "config": {
    "photo.quigs.ghostcms.publisher": {
      "values": {
        "siteUrl": "https://staging.example.com"
      },
      "secrets": {
        "API_KEY": "ghost-api-key-staging"
      }
    }
  }
}
```

Only keys that differ from the base config need to appear in the workflow override. The `config` field is added to the `Workflow` struct as a required field. Existing workflow files without it will fail to decode and must be migrated.

### Runtime resolution

When executing a plugin in a workflow:

1. Load base config from `~/.config/piqley/config/<plugin-identifier>.json`
2. Load workflow overrides from the workflow JSON's `config.<plugin-identifier>` section
3. Merge: workflow values override base values, workflow secret aliases override base secret aliases
4. Resolve each secret alias to its actual value from the keychain
5. Pass to the plugin binary as environment variables: `PIQLEY_CONFIG_<KEY>` and `PIQLEY_SECRET_<KEY>` (uppercased, hyphens and dots replaced with underscores, other non-alphanumeric characters stripped)

### Secret alias model

Secrets use a layer of indirection:

- The config file stores a **name** (alias), not the secret value
- The keychain stores entries keyed by alias name (service: `piqley`, account: alias name)
- Multiple workflows can reference the same alias, so updating one keychain entry updates all workflows that use it
- To "branch" a secret for a specific workflow, create a new keychain entry with a new alias and point the workflow override at it

### Setup flow

**`piqley plugin install`:**

1. Reads config entries from the installed plugin's `manifest.json`
2. Writes default config values to `~/.config/piqley/config/<plugin-identifier>.json`
3. Prompts for secret values, stores them in the keychain with default alias names (e.g., `<plugin-identifier>-<secret-key>`)
4. Writes the default secret alias references to the base config file
5. Runs the setup binary if defined in the manifest

**`piqley workflow config` (interactive):**

```
piqley workflow config <workflow-name> <plugin-identifier>
```

Prompts through each config value and secret alias for the given plugin in the given workflow, showing current resolved values. Secret values are never displayed. User can accept the current value (base or existing override) or provide a new one. For secrets, user can repoint to a different alias or create a new one.

**`piqley workflow config` (flag-based):**

```
piqley workflow config <workflow-name> <plugin-identifier> --set key=value
piqley workflow config <workflow-name> <plugin-identifier> --set-secret KEY=alias-name
```

Sets individual config value overrides or secret alias overrides for a specific workflow.

### Removal of config.json sidecar

The per-plugin `config.json` sidecar file (previously at `~/.config/piqley/plugins/<plugin-identifier>/config.json`) is removed. Its responsibilities are replaced by:

- Config values: `~/.config/piqley/config/<plugin-identifier>.json`
- `isSetUp` flag: moved into the base config file
- The `Packager` no longer writes a `config.json` into the `.piqleyplugin` archive

### Secret cleanup

**Automatic:** `piqley workflow delete` collects all secret aliases referenced by the workflow being deleted (including aliases inherited from base config for plugins the workflow uses), checks if any other workflow references each alias, and deletes orphaned keychain entries.

**Manual:** `piqley secret prune` scans all base config files and all workflow files, collects the union of all referenced secret aliases, and deletes any keychain entries under the `piqley` service that are not referenced. This handles cases where a workflow file was manually deleted or corrupted.

**SecretStore.list():** A new `list()` method must be added to the `SecretStore` protocol to enumerate all stored secrets. On macOS this uses `SecItemCopyMatching` with `kSecMatchLimitAll`; on Linux it lists keys from the JSON dictionary.

## Migration

Existing plugins with `config.json` sidecars need migration. The CLI detects migration is needed when an installed plugin has a `config.json` sidecar but no corresponding `~/.config/piqley/config/<plugin-identifier>.json` file. Migration runs automatically before any command that reads plugin config.

1. For each installed plugin with a `config.json`, read its values and create the corresponding `~/.config/piqley/config/<plugin-identifier>.json` with the `values` and `isSetUp` fields
2. Migrate existing secrets from `piqley.plugins.<identifier>.<key>` keychain format to the new alias-based format (alias name: `<plugin-identifier>-<secret-key>`), writing the alias mappings to the base config's `secrets` section
3. Delete the old `config.json` sidecar

Workflow files do not need modification during migration. Workflows without explicit overrides inherit from the base config, which is the same behavior as the old model where all workflows shared one set of values.

## Scope

### In scope
- `ConfigRegistry` DSL, `Config` and `Secret` builder structs (SDK)
- `ConfigComponentBuilder` result builder (SDK)
- Rename `piqley-stage-gen` to `piqley-manifest-gen` (SDK template)
- `config-entries.json` generation in manifest-gen tool (SDK template)
- Swift `Packager` reads `config-entries.json` instead of `BuildManifest.config` (SDK)
- New `BasePluginConfig` type for the base config file format (CLI, distinct from the existing runtime `PluginConfig`)
- Base config storage at `~/.config/piqley/config/<plugin-identifier>.json` (CLI)
- Workflow-scoped config overrides in workflow JSON (CLI)
- Secret alias model with keychain storage (CLI)
- `SecretStore.list()` method for enumerating stored secrets (CLI)
- `piqley workflow config` command: interactive and flag-based modes (CLI)
- Secret cleanup on workflow delete and `piqley secret prune` (CLI)
- Migration from `config.json` sidecar to new layout (CLI)
- Update `piqley plugin install` setup flow (CLI)
- Update `piqley plugin uninstall` to delete base config file and prune orphaned secrets (CLI)
- Remove `config.json` from `.piqleyplugin` archive (SDK)

### Out of scope
- Displaying secret values in any CLI mode
- Non-Swift language SDKs (they continue using build manifest config)
- Per-stage secret scoping
- Plugin upgrade config reconciliation (adding/removing config keys on plugin update)
