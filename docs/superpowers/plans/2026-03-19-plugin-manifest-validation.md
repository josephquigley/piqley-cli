# Plugin Manifest Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `pluginProtocolVersion` to `pluginSchemaVersion` across all three repos and add fail-fast manifest validation at plugin discovery time.

**Architecture:** Bottom-up rename (PiqleyCore → PiqleyPluginSDK → piqley-cli), then add validation logic to PiqleyCore's ManifestValidator and piqley-cli's PluginDiscovery. The decoder accepts both the old and new JSON key for backward compatibility.

**Tech Stack:** Swift 6, Swift Testing, PiqleyCore, PiqleyPluginSDK, piqley-cli

**Spec:** `docs/superpowers/specs/2026-03-19-plugin-manifest-validation-design.md`

---

## File Structure

### PiqleyCore (modified files)
| File | Responsibility |
|------|---------------|
| `Sources/PiqleyCore/Manifest/PluginManifest.swift` | Rename field, add `supportedSchemaVersions`, backward-compat decoder |
| `Sources/PiqleyCore/Validation/ManifestValidator.swift` | Add schema version compatibility check |
| `Tests/PiqleyCoreTests/ManifestCodingTests.swift` | Update all `pluginProtocolVersion` references |
| `Tests/PiqleyCoreTests/ManifestValidatorTests.swift` | Update helper, add unsupported version test |

### PiqleyPluginSDK (modified files)
| File | Responsibility |
|------|---------------|
| `swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift` | Rename `ProtocolVersion` component handling |
| `swift/Tests/ManifestBuilderTests.swift` | Update all assertions |
| `schemas/manifest.schema.json` | Rename JSON key |

### piqley-cli (modified files)
| File | Responsibility |
|------|---------------|
| `Sources/piqley/Plugins/PluginDiscovery.swift` | Add validation, add `PluginDiscoveryError` |
| `Sources/piqley/CLI/InstallCommand.swift` | Use `PluginManifest.supportedSchemaVersions` |
| `Sources/piqley/CLI/PluginCommand.swift` | Rename in init |
| `Sources/piqley/Plugins/PluginSetupScanner.swift` | Rename `pluginProtocolVersion` reference |
| `Sources/piqley/Constants/SecretNamespace.swift` | Rename constant |
| `Tests/piqleyTests/*.swift` | Rename in all test files |

---

### Task 1: Rename field in PiqleyCore and add supportedSchemaVersions

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ManifestCodingTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ManifestValidatorTests.swift`

- [ ] **Step 1: Update PluginManifest**

Rename `pluginProtocolVersion` → `pluginSchemaVersion` everywhere in the struct. Add `supportedSchemaVersions`. Update the decoder to accept both `pluginSchemaVersion` and `pluginProtocolVersion` JSON keys for backward compatibility.

- [ ] **Step 2: Update ManifestCodingTests**

Replace all `pluginProtocolVersion` with `pluginSchemaVersion` in test JSON strings and assertions.

- [ ] **Step 3: Update ManifestValidatorTests**

Replace `pluginProtocolVersion` with `pluginSchemaVersion` in the helper and test names.

- [ ] **Step 4: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add -A
git commit -m "feat: rename pluginProtocolVersion to pluginSchemaVersion, add supportedSchemaVersions"
```

---

### Task 2: Add schema version validation to ManifestValidator

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Validation/ManifestValidator.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ManifestValidatorTests.swift`

- [ ] **Step 1: Add unsupported version test**

```swift
@Test func unsupportedSchemaVersionFails() {
    let manifest = makeManifest(pluginSchemaVersion: "999")
    let errors = ManifestValidator.validate(manifest)
    #expect(errors.contains { $0.contains("999") })
}

@Test func supportedSchemaVersionPasses() {
    let manifest = makeManifest(pluginSchemaVersion: "1")
    let errors = ManifestValidator.validate(manifest)
    #expect(errors.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ManifestValidator 2>&1 | tail -20`

- [ ] **Step 3: Add validation check**

In `ManifestValidator.validate()`, add after the empty check:

```swift
if !PluginManifest.supportedSchemaVersions.contains(manifest.pluginSchemaVersion) {
    let supported = PluginManifest.supportedSchemaVersions.sorted().joined(separator: ", ")
    errors.append("Unsupported schema version '\(manifest.pluginSchemaVersion)' (supported: \(supported)).")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add -A
git commit -m "feat: add schema version compatibility check to ManifestValidator"
```

---

### Task 3: Rename in PiqleyPluginSDK

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/ManifestBuilderTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/schemas/manifest.schema.json`
- Modify: All other SDK files with `pluginProtocolVersion` references

- [ ] **Step 1: Rename across all SDK source and test files**

Mechanical find-and-replace of `pluginProtocolVersion` → `pluginSchemaVersion` across all Swift files and JSON schemas in the SDK repo. The `ProtocolVersion` builder component name stays the same (it's a DSL name, not a field name) but its internal handling references the renamed field.

- [ ] **Step 2: Run SDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add -A
git commit -m "feat: rename pluginProtocolVersion to pluginSchemaVersion across SDK"
```

---

### Task 4: Rename in piqley-cli source and tests

**Files:**
- Modify: All CLI source files with `pluginProtocolVersion` references
- Modify: All CLI test files with `pluginProtocolVersion` references

- [ ] **Step 1: Rename across all CLI source and test files**

Mechanical find-and-replace of `pluginProtocolVersion` → `pluginSchemaVersion` across all Swift files in the CLI repo. Key files: `InstallCommand.swift`, `PluginCommand.swift`, `PluginSetupScanner.swift`, `SecretNamespace.swift`, and all test files.

- [ ] **Step 2: Update InstallCommand to use PluginManifest.supportedSchemaVersions**

Replace `PluginInstaller.supportedProtocolVersions` with `PluginManifest.supportedSchemaVersions`. Remove the local `supportedProtocolVersions` constant. Update the error case name from `unsupportedProtocolVersion` to `unsupportedSchemaVersion`.

- [ ] **Step 3: Run CLI tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add -A
git commit -m "feat: rename pluginProtocolVersion to pluginSchemaVersion across CLI"
```

---

### Task 5: Add fail-fast validation to PluginDiscovery

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginDiscovery.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginDiscoveryTests.swift`

- [ ] **Step 1: Add PluginDiscoveryError type and validation tests**

Add tests for:
- Unsupported schema version throws
- Identifier/directory name mismatch throws
- No stage files throws
- Valid plugin passes

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter PluginDiscovery 2>&1 | tail -20`

- [ ] **Step 3: Add PluginDiscoveryError and validation to loadManifests**

Add error type:
```swift
enum PluginDiscoveryError: Error, LocalizedError {
    case invalidManifest(plugin: String, path: String, reasons: [String])
    case identifierMismatch(plugin: String, path: String, directoryName: String)
    case noStageFiles(plugin: String, path: String)

    var errorDescription: String? {
        switch self {
        case let .invalidManifest(plugin, path, reasons):
            "Plugin '\(plugin)' has invalid manifest: \(reasons.joined(separator: "; "))\n  at \(path)"
        case let .identifierMismatch(plugin, path, directoryName):
            "Plugin '\(plugin)': identifier does not match directory name '\(directoryName)'\n  at \(path)"
        case let .noStageFiles(plugin, path):
            "Plugin '\(plugin)' has no valid stage files\n  at \(path)"
        }
    }
}
```

In `loadManifests`, after decoding the manifest:
1. Run `ManifestValidator.validate()` — if errors, throw `.invalidManifest`
2. Check `manifest.identifier == dirName` — if mismatch, throw `.identifierMismatch`
3. Check `!stages.isEmpty` — if empty, throw `.noStageFiles`

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter PluginDiscovery 2>&1 | tail -20`

- [ ] **Step 5: Run full CLI test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Fix any tests that now fail due to the new validation (e.g., tests that create plugins without stage files or with mismatched identifiers).

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add -A
git commit -m "feat: add fail-fast manifest validation at plugin discovery"
```

---

### Task 6: Cross-repo verification

- [ ] **Step 1: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

- [ ] **Step 2: Run PiqleyPluginSDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

- [ ] **Step 3: Run piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

- [ ] **Step 4: Build release**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build -c release 2>&1 | tail -10`
