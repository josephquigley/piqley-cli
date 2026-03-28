# Plugin Update Command

## Summary

Add `piqley plugin update <path>` command that replaces plugin files from a new `.piqleyplugin` zip while preserving existing config values and secrets. New manifest entries are prompted, removed entries are deleted with a printed notice, and type-changed entries are re-prompted.

## Motivation

Currently `plugin install --force` overwrites everything, including config and secrets. When a plugin author ships a new version, users lose their configuration. The update command provides a safe upgrade path that merges configuration intelligently.

## Design

### New files

- `Sources/piqley/CLI/UpdateCommand.swift`: contains `PluginUpdater` enum and `UpdateSubcommand` struct

### Registration

`UpdateSubcommand` is added to `PluginCommand.subcommands` in `PluginCommand.swift`.

### CLI interface

```
piqley plugin update <pluginFile>
```

- `pluginFile`: path to a `.piqleyplugin` zip (same as install)
- No `--force` flag. The command always overwrites plugin files (that is its purpose). Config/secret merging is the default and only behavior.

### Preconditions

- File must exist and have `.piqleyplugin` extension (same validation as install)
- Plugin must already be installed (error if not: "Plugin '{id}' is not installed. Use 'piqley plugin install' instead.")

### UpdateError enum

Separate from `InstallError`, with its own cases:

- `fileNotFound`: "Plugin file not found."
- `notAPiqleyPlugin`: "File does not have a .piqleyplugin extension."
- `missingManifest`: "Plugin archive does not contain a manifest.json."
- `invalidManifest`: "Plugin manifest is invalid."
- `unsupportedSchemaVersion`: "Plugin schema version is not supported."
- `notInstalled`: "Plugin '{id}' is not installed. Use 'piqley plugin install' instead."
- `identifierMismatch(old, new)`: "Cannot update: installed plugin is '{old}' but the package contains '{new}'."
- `unsupportedPlatform(host, supported)`: same format as InstallError
- `extractionFailed`: "Failed to extract plugin archive."

### PluginUpdater.update() flow

Reuses the same extraction/validation logic as `PluginInstaller.install()`:

1. Extract zip to temp directory
2. Find plugin directory in extracted contents
3. Read and decode new manifest
4. Validate schema version
5. Run ManifestValidator
6. Check platform support
7. Flatten platform-specific bin/data directories
8. **Verify plugin is installed** (plugin directory must exist at `{pluginsDir}/{identifier}`, else throw `notInstalled`)
9. **Read old manifest** from installed plugin directory
10. **Verify identifier match** (old manifest identifier must equal new manifest identifier, else throw `identifierMismatch`)
11. **Delete old plugin directory** and move new one into place
12. Write `installedPlatform` to manifest
13. Set executable permissions on bin/ files
14. Create logs/ and data/ directories if missing
15. Return `(identifier, oldManifest, newManifest)` tuple

Steps 1-7 and 11-14 are identical to `PluginInstaller`. Steps 8-10 are new. The method returns both manifests so the caller can perform config merging.

Note: stage files (`stage-*.json`) are replaced along with all other plugin files. Users who have hand-edited stage files should back them up before updating.

### UpdateSubcommand.run() flow

1. Call `PluginUpdater.update()` to get `(identifier, oldManifest, newManifest)`
2. Print version transition if both manifests have `pluginVersion` (e.g., "Updating from 1.2.0 to 1.3.0")
3. Load existing `BasePluginConfig` from `BasePluginConfigStore`
4. Diff old vs new manifest config entries (see merge algorithm below)
5. Build merged `BasePluginConfig` and save it to the config store
6. Run `PluginSetupScanner.scan()` with `skipValueKeys` and `skipSecretKeys` to prompt only for new/changed entries and re-run the setup binary
7. Print completion message

### Config merge algorithm

Build keyed lookups from old and new `manifest.config` arrays:
- For `.value(key, type, value)`: keyed by `key`
- For `.secret(secretKey, type)`: keyed by `secretKey`

For each entry in the **new** manifest:

| Scenario | Action |
|---|---|
| Key exists in old manifest, same type | Add to `skipValueKeys` or `skipSecretKeys`. Carry over existing value in merged config. |
| Key exists in old manifest, different type | Print notice: "Config '{key}' type changed from {old} to {new}, re-prompting." Remove old value from merged config so scanner will prompt. |
| Key is new (not in old manifest) | Do nothing here; scanner will prompt for it. |

For each entry in the **old** manifest not present in the new:

| Entry type | Action |
|---|---|
| `.value` | Remove from `baseConfig.values`. Print: "Removed config '{key}' (no longer in manifest)." |
| `.secret` | Remove from `baseConfig.secrets`. Print: "Removed secret '{key}' (no longer in manifest)." |

After the merge and scan, run `SecretPruner.prune()` to clean up any orphaned secrets from the keychain.

### Setup binary handling

If the new manifest declares a `setup` config:
- Reset `isSetUp` to `nil` in the merged config before passing to scanner, so the setup binary always re-runs
- The existing `PluginSetupScanner` Phase 3 logic handles execution

### PluginSetupScanner changes

Add two optional parameters to `scan()`:

```swift
mutating func scan(
    plugin: LoadedPlugin,
    force: Bool = false,
    skipValueKeys: Set<String> = [],
    skipSecretKeys: Set<String> = []
) throws
```

When provided:
- Phase 1 (config values): skip prompting for keys in `skipValueKeys`, carry over their existing values (same behavior as the existing `!force && existing != nil` check, but explicitly controlled)
- Phase 2 (secrets): skip prompting for secret keys in `skipSecretKeys`
- Phase 3 (setup binary): runs as normal (no change)

The update command saves the pre-populated merged config to the store before calling `scan()`, so when the scanner loads the config at the start, the carried-over values are already present. Combined with `skipValueKeys`/`skipSecretKeys`, this ensures only new or type-changed entries are prompted.

### Example session

```
$ piqley plugin update ~/Downloads/photo.quigs.ghostcms.publisher.piqleyplugin

Updating photo.quigs.ghostcms.publisher from 1.0.0 to 1.1.0
Plugin files updated successfully.

Running setup for 'Ghost CMS Publisher'...

[Ghost CMS Publisher] Kept apiUrl = https://my-blog.com
[Ghost CMS Publisher] Kept postTemplate = default
[Ghost CMS Publisher] newSetting: ← user prompted
Removed config 'oldDeprecatedKey' (no longer in manifest).
Removed secret 'OLD_API_TOKEN' (no longer in manifest).
Pruned 1 orphaned secret(s).
[Ghost CMS Publisher] API_KEY (secret) already set

Setup complete.
```

## Testing

- Unit test `PluginUpdater` with temp directories (same pattern as install tests)
- Unit test config merge logic: kept values, new values prompted, removed values noticed, type changes re-prompted
- Unit test `PluginSetupScanner.scan(skipValueKeys:skipSecretKeys:)` with mock `InputSource`
- Unit test identifier mismatch error
- Integration test: install a plugin, then update with a modified manifest, verify merged config
