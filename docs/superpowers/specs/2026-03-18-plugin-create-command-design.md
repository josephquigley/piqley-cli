# Plugin Create Command — Design Spec

## Summary

Add a `piqley plugin create` subcommand that scaffolds a standalone plugin project from a skeleton bundled in the SDK repository. The command fetches the appropriate SDK release, extracts a language-specific skeleton, and writes a ready-to-build project to a target directory.

## Command Interface

```
piqley plugin create <target-directory> [--language <lang>] [--name <plugin-name>] [--sdk-repo-url <url>]
```

| Argument / Option | Required | Default | Description |
|---|---|---|---|
| `target-directory` | Yes | — | Path where the project is written |
| `--language` | No | `swift` | Language skeleton to use (lowercased to match `Skeletons/<lang>/`) |
| `--name` | No | Derived from target directory's last path component | Plugin name used in generated files |
| `--sdk-repo-url` | No | `https://github.com/josephquigley/piqley-plugin-sdk` | Git remote for fetching tags and downloading the archive |

### Name Derivation

If `--name` is not provided, the plugin name is derived from the last path component of `target-directory`. The same validation rules from the existing `InitSubcommand.validatePluginName` apply (no empty names, no reserved names, no path separators, no whitespace).

## Version Resolution

1. Read the CLI's major version from `AppConstants.version`.
2. Run `git ls-remote --tags <sdk-repo-url>` to list all tags.
3. Parse tags as semantic versions, filter to those matching the CLI's major version.
4. Select the highest matching tag.
5. Error if no compatible release is found.

## Skeleton Fetch

1. Download `<sdk-repo-url>/archive/refs/tags/<tag>.tar.gz` to a temporary directory.
2. Extract the tarball.
3. Locate `Skeletons/<language>/` inside the extracted contents (language is lowercased from the `--language` argument).
4. Copy the skeleton contents to `target-directory`.
5. Clean up temporary files.

The `--language` value is lowercased before lookup. No hardcoded language enum exists in the CLI — the archive contents are the source of truth for which languages are available.

## Template Substitution

After copying skeleton files, the following placeholders are replaced in all files:

| Placeholder | Replaced With |
|---|---|
| `__PLUGIN_NAME__` | Resolved plugin name |
| `__SDK_VERSION__` | Matched semver tag (without leading `v` if present) |

## Swift Skeleton

Lives in the SDK repo at `Skeletons/swift/`. Produces a buildable Swift package.

### `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "__PLUGIN_NAME__",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/josephquigley/piqley-plugin-sdk",
            .upToNextMajor(from: "__SDK_VERSION__")
        ),
    ],
    targets: [
        .executableTarget(
            name: "__PLUGIN_NAME__",
            dependencies: [
                .product(name: "PiqleyPluginSDK", package: "piqley-plugin-sdk"),
            ]
        ),
    ]
)
```

### `Sources/main.swift`

Minimal `PiqleyPlugin` conformance with a `handle` stub returning `.ok`.

### `.gitignore`

Standard Swift package ignores (`.build/`, `.swiftpm/`, `Package.resolved`, etc.).

### Note

The skeleton's `Package.swift` always points to the canonical GitHub URL for the SDK dependency, regardless of `--sdk-repo-url`. The override only affects the CLI's fetch behavior when resolving which version to scaffold.

## Error Handling

| Condition | Behavior |
|---|---|
| Target directory exists and is non-empty | Fail with clear message, do not overwrite |
| No compatible semver tag found | Fail explaining the CLI major version and what was searched |
| `git ls-remote` fails | Fail with underlying error (network, auth, bad URL) |
| Tarball download or extraction fails | Fail, clean up temp files |
| `Skeletons/<language>/` not found in archive | Fail explaining the language is not available in that SDK release |

## Integration

- Register `CreateSubcommand` as a new subcommand of the existing `PluginCommand` alongside `setup` and `init`.
- Reuse `InitSubcommand.validatePluginName` for name validation (or extract to a shared utility).
- The skeleton files are authored in the `piqley-plugin-sdk` repo, not the CLI repo. The CLI only fetches and templates them.
