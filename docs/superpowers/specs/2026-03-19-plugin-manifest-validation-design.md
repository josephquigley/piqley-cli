# Plugin Manifest Validation at Discovery

## Problem

Plugins with unsupported protocol versions (or other invalid manifests) load and run silently. A plugin with `pluginProtocolVersion: "2"` runs through the entire pipeline without any warning or error. The CLI should refuse to run if any plugin in the plugins directory has an invalid manifest, rather than executing a half-baked pipeline.

## Design

Two changes: (1) rename `pluginProtocolVersion` to `pluginSchemaVersion` across all three repos, and (2) add fail-fast validation at discovery.

### Rename: `pluginProtocolVersion` → `pluginSchemaVersion`

"Schema version" accurately describes what this field controls — the shape of the manifest and stage JSON files the CLI knows how to read. "Protocol" incorrectly implies a communication format.

This is a mechanical rename across:
- **PiqleyCore**: `PluginManifest` field, `CodingKeys`, init, decoder, `ManifestValidator`
- **PiqleyPluginSDK**: `ProtocolVersion` manifest builder component, `ManifestBuilder`, schemas
- **piqley-cli**: `PluginCommand` (init), `InstallCommand`, `PluginSetupScanner`, all tests

The JSON key in manifest files changes from `"pluginProtocolVersion"` to `"pluginSchemaVersion"`. For backward compatibility during transition, the decoder should accept either key.

### Validation at Discovery

Fail-fast at discovery. `PluginDiscovery.loadManifests()` validates every manifest immediately after decoding. If any plugin fails validation, the method throws with an error that names the plugin, its path, and the specific problem.

### PiqleyCore Changes

**`PluginManifest.swift`** — rename field and add a static constant for the supported schema version set:

```swift
public let pluginSchemaVersion: String
public static let supportedSchemaVersions: Set<String> = ["1"]
```

This is the single source of truth for schema compatibility across the CLI, SDK, and core.

**`ManifestValidator.swift`** — expand `validate()` to include schema version checking:

Current checks (kept, with rename):
- `identifier` must not be empty
- `name` must not be empty
- `pluginSchemaVersion` must not be empty

New check:
- `pluginSchemaVersion` must be in `PluginManifest.supportedSchemaVersions`

The method continues to return `[String]` (a list of error messages). The schema version error message includes the unsupported version and the set of supported versions.

### piqley-cli Changes

**`PluginDiscovery.loadManifests()`** — after decoding each manifest, validate before adding to the result:

1. Run `ManifestValidator.validate()` — if errors, throw.
2. Check `manifest.identifier == directory.lastPathComponent` — the plugin's directory name must match its identifier.
3. Check at least one valid stage file was loaded — a plugin with no stages does nothing and is likely misconfigured.

If any check fails, throw a `PluginDiscoveryError` with:
- The plugin identifier
- The full filesystem path to the plugin directory
- The specific validation failure

Example error messages (path follows the error to reduce cognitive load):
```
Plugin 'com.example.foo' has unsupported protocol version '2' (supported: 1)
  at /Users/wash/.config/piqley/plugins/com.example.foo
```
```
Plugin 'com.example.bar': identifier does not match directory name 'wrong-name'
  at /Users/wash/.config/piqley/plugins/com.example.bar
```
```
Plugin 'com.example.baz' has no valid stage files
  at /Users/wash/.config/piqley/plugins/com.example.baz
```

**`InstallCommand.swift`** — remove the local `supportedProtocolVersions` set. Use `PluginManifest.supportedProtocolVersions` instead.

### Error Type

Add a new error type in the CLI:

```swift
enum PluginDiscoveryError: Error, LocalizedError {
    case invalidManifest(plugin: String, path: String, reasons: [String])
    case identifierMismatch(plugin: String, path: String, directoryName: String)
    case noStageFiles(plugin: String, path: String)
}
```

Each case produces a human-readable `errorDescription` that includes the plugin identifier and full path.

### Behavior

- A single invalid plugin aborts the entire CLI run.
- The user must fix or remove the offending plugin to proceed.
- No partial pipeline execution.
- Disabled plugins (in `config.disabledPlugins`) are still skipped before validation — disabling a broken plugin is a valid escape hatch.

### What This Does NOT Change

- Stage file validation remains warn-and-skip (unknown stage names, malformed JSON within a stage file). These are non-fatal because a plugin can function with a subset of its stages.
- Rule compilation errors remain per-plugin failures at execution time.
- Secret validation remains per-plugin at execution time.
