# Clone Emit Action — Implementation Plan

Spec: `docs/superpowers/specs/2026-03-19-clone-emit-action-design.md`

## Step 1: PiqleyCore — Add `source` to EmitConfig (breaking change)

**Files:**
- `piqley-core/Sources/PiqleyCore/Config/Rule.swift`

**Changes:**
- Add `public let source: String?` property to `EmitConfig`
- Replace `init` with fully explicit parameters: `action: String?, field: String, values: [String]?, replacements: [Replacement]?, source: String?` — no defaults on any parameter

**Tests:**
- `piqley-core/Tests/PiqleyCoreTests/ConfigCodingTests.swift`
- Update all 4 `EmitConfig(` call sites to pass `source: nil`
- Add encoding/decoding round-trip test for clone action: `EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")`
- Add JSON decoding test for wildcard clone: `{ "action": "clone", "field": "*", "source": "original" }`

**Verify:** `cd piqley-core && swift test`

## Step 2: PiqleyPluginSDK — Update call sites and add clone cases

**Files:**
- `piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`

**Changes:**
- Update all 8 `EmitConfig(` calls in `toEmitConfig()` to pass `source: nil`
- Add 3 new `RuleEmit` cases: `clone(field:source:)`, `cloneKeywords(source:)`, `cloneAll(source:)`
- Add `toEmitConfig()` mappings for the 3 new cases

**Tests:**
- `piqley-plugin-sdk/swift/Tests/ConfigBuilderTests.swift`
- Add tests for `clone`, `cloneKeywords`, `cloneAll` → verify `toEmitConfig()` output

**Verify:** `cd piqley-plugin-sdk/swift && swift test`

## Step 3: CLI — EmitAction enum and compilation

**Files:**
- `piqley-cli/Sources/piqley/State/RuleEvaluator.swift`

**Changes:**
- Add `case clone(field: String, sourceNamespace: String, sourceField: String?)` to `EmitAction`
- Add `"clone"` case to `compileEmitAction`: validate `source` non-nil/non-empty, `values` nil, `replacements` nil; parse source via `splitField`; when field is `"*"`, sourceField is nil
- Add `source` rejection to all other action cases: `guard config.source == nil`

**Tests (compilation only):**
- `piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`
- Update all 23 existing `EmitConfig(` calls to pass `source: nil`
- Add compilation validation tests:
  - clone with valid source compiles
  - clone with nil source → error
  - clone with values present → error
  - clone with replacements present → error
  - add/remove/replace/removeField with source present → error

**Verify:** `swift test --filter RuleEvaluatorTests`

## Step 4: CLI — Clone evaluation logic

**Files:**
- `piqley-cli/Sources/piqley/State/RuleEvaluator.swift`

**Changes:**
- In `evaluate`, handle `.clone` inline before delegating other actions to `applyAction`:
  - Single field: resolve `sourceNamespace`/`sourceField` from `state` (or `MetadataBuffer` for `read:`), overwrite `working[field]`
  - Wildcard: copy all fields from source namespace into `working`
  - No-op if source doesn't exist

**Tests (evaluation):**
- Single-field clone from `original` namespace
- Wildcard clone copies all fields, preserves existing unrelated fields
- Clone overwrites existing values (not merge)
- Clone from non-existent source is no-op
- Clone followed by remove (the motivating use case)
- Clone with `read:` namespace (mock MetadataBuffer)

**Verify:** `swift test --filter RuleEvaluatorTests`

## Step 5: Verify full test suite

**Verify:** Run full test suite across all three repos:
- `cd piqley-core && swift test`
- `cd piqley-plugin-sdk/swift && swift test`
- `swift test` (piqley-cli)
