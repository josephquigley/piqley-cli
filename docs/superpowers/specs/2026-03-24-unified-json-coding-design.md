# Unified JSON Encoder/Decoder Design

## Problem

Bare `JSONEncoder()` and `JSONDecoder()` calls are scattered across all three piqley repos (piqley-core, piqley-cli, piqley-plugin-sdk). There is no centralized, shared coding configuration.

## Solution

Add static computed properties on `JSONEncoder` and `JSONDecoder` via extensions in PiqleyCore. Replace all bare initializers across the three repos with the appropriate shared variant.

## API Surface

New file: `Sources/PiqleyCore/JSONCoding+Piqley.swift`

```swift
import Foundation

extension JSONEncoder {
    public static var piqley: JSONEncoder { JSONEncoder() }
    public static var piqleyPrettyPrint: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var piqley: JSONDecoder { JSONDecoder() }
}
```

### Variants

| Variant | Purpose | Used by |
|---------|---------|---------|
| `JSONEncoder.piqley` | Default in-memory encoding | Plugin communication, test round-trips, secret stores |
| `JSONEncoder.piqleyPrettyPrint` | Human-readable config files on disk | WorkflowStore, StageFileManager, BasePluginConfigStore, PluginConfig, StageRegistry, all SDK builders |
| `JSONDecoder.piqley` | Default decoding | Everything |

### Exclusions

- `ExecutionLog.swift` in piqley-plugin-sdk retains its private ISO 8601 encoder/decoder (one-off use case).
- `_migrate/` directory in piqley-cli is untouched (legacy code).
- Documentation and plan `.md` files containing code snippets are not modified.

## Migration Plan

Pure mechanical replacement, no behavioral changes.

### PiqleyCore

- **StageRegistry.swift**: `JSONEncoder()` + formatting → `.piqleyPrettyPrint`, `JSONDecoder()` → `.piqley`
- **All test files**: bare inits → `.piqley` variants

### piqley-cli

- **Config writers** (WorkflowStore, BasePluginConfigStore, PluginConfig, StageFileManager, PluginCommand.writeJSON): `JSONEncoder()` + formatting → `.piqleyPrettyPrint`
- **Plain decode sites** (InstallCommand, PluginRulesCommand, PluginDiscovery, ConfigMigrator, PipelineOrchestrator+Helpers, PluginCommandEditCommand, SecretPruner): `JSONDecoder()` → `.piqley`
- **PluginRunner.swift**: `JSONEncoder()` → `.piqley`, `JSONDecoder()` → `.piqley` (IPC, not disk writes)
- **FileSecretStore**: plain `JSONEncoder()` → `.piqley`
- **All test files**: bare inits → `.piqley` variants

### piqley-plugin-sdk

- **Builders** (HookRegistry, StageBuilder, ConfigBuilder, ConfigRegistryBuilder, ManifestBuilder): `JSONEncoder()` + formatting → `.piqleyPrettyPrint`
- **Runtime** (Plugin.swift, Request.swift, BuildManifest.swift, Packager.swift): bare inits → `.piqley` variants
- **ExecutionLog.swift**: untouched
- **All test files**: bare inits → `.piqley` variants

## Testing

Existing test suites cover all encode/decode paths. No new tests needed since this is a behavioral no-op. All three repos' tests must pass after migration.
