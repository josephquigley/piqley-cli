# Multi-Platform Plugin Support

## Summary

Add platform/architecture awareness to the plugin system so a single `.piqleyplugin` package can contain binaries and data for multiple platforms. The CLI filters to the host platform at install time, keeping runtime behavior unchanged.

Supported platforms: `macos-arm64`, `linux-amd64`, `linux-arm64`. Intel Macs (`macos-amd64`) are intentionally excluded. The platform list can be extended later by adding new keys without structural changes.

## Build Manifest Changes

The `bin` and `data` fields change from flat arrays to objects keyed by platform triple. This is a breaking change: `pluginSchemaVersion` bumps to `"2"`. The CLI and SDK will reject schema version `"1"` manifests that use the old flat format with a clear error directing the author to migrate.

**Before (schema v1):**
```json
{
  "pluginSchemaVersion": "1",
  "bin": [".build/release/my-plugin"],
  "data": ["models/model.bin"]
}
```

**After (schema v2):**
```json
{
  "pluginSchemaVersion": "2",
  "bin": {
    "macos-arm64": [".build/release/my-plugin"],
    "linux-amd64": ["dist/my-plugin-amd64"],
    "linux-arm64": ["dist/my-plugin-arm64"]
  },
  "data": {
    "macos-arm64": ["models/mac-model.bin"],
    "linux-amd64": ["models/linux-model.bin"],
    "linux-arm64": ["models/linux-model.bin"]
  }
}
```

- At least one platform must be declared in `bin`.
- `data` is optional but follows the same keyed structure if present.
- If `data` is present, its platform keys must be a subset of `bin`'s platform keys. A plugin cannot declare data for a platform it has no binary for.
- Interpreted plugins (Node, Python) use separate entries per platform. Shared logic can be factored into common files that the per-platform entry point calls.

### Affected files
- `piqley-plugin-sdk`: `BuildManifest.swift` (struct, decoder, and `toPluginManifest()`), `build-manifest.schema.json`
- `piqley-plugin-sdk`: `Tests/SchemaConformanceTests.swift`, `Tests/PackagerTests.swift`

## Package Structure

The `.piqleyplugin` ZIP uses platform-keyed subdirectories under `bin/` and `data/`:

```
my-plugin/
  manifest.json
  config.json
  stage-process.json
  bin/
    macos-arm64/
      my-plugin
    linux-amd64/
      my-plugin
    linux-arm64/
      my-plugin
  data/
    macos-arm64/
      mac-model.bin
    linux-amd64/
      linux-model.bin
    linux-arm64/
      linux-model.bin
```

The Packager reads the build manifest's platform keys and stages files into the corresponding subdirectories.

### Affected files
- `piqley-plugin-sdk`: `Packager.swift`

## Runtime Manifest Changes

`PluginManifest` gains one new field:

- `supportedPlatforms: [String]`: list of platform triples this plugin was packaged for (e.g., `["macos-arm64", "linux-amd64"]`).

Populated by `BuildManifest.toPluginManifest()` from the build manifest's `bin` keys. Written into `manifest.json`. Used at install time to validate compatibility. Has no effect at runtime after installation.

The `manifest.schema.json` adds `supportedPlatforms` as an array of strings.

### Affected files
- `piqley-core`: `PluginManifest.swift`
- `piqley-plugin-sdk`: `manifest.schema.json`, `Packager.swift`, `BuildManifest.swift` (`toPluginManifest()`)

## Host Platform Detection

The CLI determines the host platform triple using Swift conditional compilation:

```swift
enum HostPlatform {
    static var current: String {
        #if os(macOS) && arch(arm64)
        return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-amd64"
        #elseif os(Linux) && arch(arm64)
        return "linux-arm64"
        #else
        fatalError("Unsupported platform")
        #endif
    }
}
```

This lives in the CLI since only the installer needs it.

### Affected files
- `piqley-cli`: new file or added to an existing constants/utility file

## Install-Time Behavior

When the CLI installs a `.piqleyplugin`:

1. Read `manifest.json` and check `supportedPlatforms` against `HostPlatform.current`. If the host platform is not listed, reject with `InstallError.unsupportedPlatform(host: String, supported: [String])`.
2. Extract the ZIP to a temp directory (existing behavior).
3. In the temp directory, before moving to the install location:
   - Move the contents of `bin/{host-platform}/` up to `bin/`, then delete all platform subdirectories under `bin/`.
   - If `data/` has platform subdirectories, move the contents of `data/{host-platform}/` up to `data/`, then delete all platform subdirectories under `data/`.
4. Move the flattened plugin directory to the install location (existing behavior).
5. Set executable permissions on `bin/` contents (existing behavior).

The installed plugin directory looks exactly like it does today: flat `bin/` and `data/` with no platform subdirectories. This means plugin discovery, binary probing, stage config resolution, and plugin execution are all unchanged.

### Affected files
- `piqley-cli`: `InstallCommand.swift`

## Template Updates

Each language template's `piqley-build-manifest.json` updates to schema v2 with the new keyed format. Templates default to a single platform placeholder that the author expands as needed.

### Affected files
- `piqley-plugin-sdk`: `templates/swift/piqley-build-manifest.json`, `templates/go/piqley-build-manifest.json`, `templates/node/piqley-build-manifest.json`, `templates/python/piqley-build-manifest.json`

## What Does NOT Change

- Plugin discovery (`PluginDiscovery.swift`)
- Binary probing (`BinaryProbe.swift`)
- Plugin execution (`PluginRunner.swift`)
- Stage config format (`StageConfig`, `HookConfig`)
- Command resolution (still resolves relative to `{plugin-dir}/bin/`)
- The `piqley-build` CLI invocation (reads the new manifest format transparently)
