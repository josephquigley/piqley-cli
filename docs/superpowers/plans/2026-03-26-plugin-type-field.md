# Plugin Type Field Implementation Plan

**Spec**: `docs/superpowers/specs/2026-03-26-plugin-type-field-design.md`

## Step 1: Add PluginType enum and type field to PluginManifest (piqley-core)

**Files:**
- `Sources/PiqleyCore/Manifest/PluginManifest.swift`

**Changes:**
1. Add `PluginType` enum above `PluginManifest`:
   ```swift
   public enum PluginType: String, Codable, Sendable, Equatable {
       case `static`
       case mutable
   }
   ```
2. Add `public let type: PluginType` property to `PluginManifest`
3. Add `type` to `CodingKeys`
4. Add `type` to `init(from:)` as required decode (no fallback)
5. Add `type` to `encode(to:)`
6. Add `type` parameter to memberwise `init(...)` (no default value)

**Tests:**
- `Tests/PiqleyCoreTests/ManifestCodingTests.swift`: Update all `PluginManifest(...)` call sites to include `type:`. Add test for decoding manifest with `"type": "static"` and `"type": "mutable"`. Add test that decoding without `type` throws.
- `Tests/PiqleyCoreTests/ManifestValidatorTests.swift`: Update all `PluginManifest(...)` call sites.

**Verify:** `swift test` passes in piqley-core.

## Step 2: Update SDK packager to set type: .static (piqley-plugin-sdk)

**Files:**
- `swift/PiqleyPluginSDK/BuildManifest.swift`

**Changes:**
1. In `toPluginManifest(...)`, pass `type: .static` to the `PluginManifest` initializer

**Tests:**
- `swift/Tests/PackagerTests.swift`: Update any `PluginManifest(...)` call sites. Verify packaged manifest has `type: .static`.

**Verify:** `swift test` passes in piqley-plugin-sdk.

## Step 3: Set type: .mutable in plugin init command (piqley-cli)

**Files:**
- `Sources/piqley/CLI/PluginCommand.swift`

**Changes:**
1. In `InitSubcommand.execute(...)`, add `type: .mutable` to both `PluginManifest(...)` initializer calls (with-examples and without-examples branches, around lines 229 and 242)

## Step 4: Add mutation guard and apply to mutation commands (piqley-cli)

**Files:**
- `Sources/piqley/CLI/PluginRulesCommand.swift`
- `Sources/piqley/CLI/PluginCommandEditCommand.swift`

**Changes:**
1. In `PluginRulesCommand.run()`: after loading the manifest (line 40), add a guard check:
   ```swift
   guard manifest.type == .mutable else {
       throw CleanError(
           "'\(manifest.name)' is a static plugin and cannot be modified. "
           + "Config values can be changed with 'piqley plugin config'."
       )
   }
   ```
2. In `PluginCommandEditCommand.run()`: after loading the manifest (around line 60), add the same guard check. Read the full file to find where manifest is decoded.

## Step 5: Update all remaining PluginManifest call sites in CLI (piqley-cli)

**Files:** All files containing `PluginManifest(` in Sources and Tests:
- `Tests/piqleyTests/UpdateCommandTests.swift`
- `Tests/piqleyTests/ConfigMigratorTests.swift`
- `Tests/piqleyTests/PluginSetupScannerTests.swift`
- `Tests/piqleyTests/PluginWorkflowResolverTests.swift`
- `Tests/piqleyTests/InstallCommandTests.swift`
- `Tests/piqleyTests/DependencyValidatorTests.swift`
- Any other files found via grep

**Changes:**
1. Add `type:` parameter to every `PluginManifest(...)` call. Use `.static` for test manifests simulating installed/bundled plugins, `.mutable` for test manifests simulating init-ed plugins.

**Verify:** `swift test` passes in piqley-cli.

## Step 6: Update bundled plugin manifests

**Files:** Any bundled plugin `manifest.json` files shipped with the CLI (in the build/distribution directory or test fixtures).

**Changes:**
1. Add `"type": "static"` to each bundled plugin manifest JSON.

**Verify:** Full `swift test` across all three repos.
