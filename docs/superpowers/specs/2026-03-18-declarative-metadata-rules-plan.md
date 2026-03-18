# Implementation Plan: Declarative Metadata Rules

**Spec:** `docs/superpowers/specs/2026-03-18-declarative-metadata-rules-design.md`

---

## Step 1: Tag Matchers (`Sources/piqley/State/TagMatcher.swift`)

Port `ExactMatcher`, `GlobMatcher`, `RegexMatcher` from `_migrate/ImageProcessing/TagMatcher.swift`. Changes from old code:
- Protocol renamed from `TagMatcher` to `TagMatcher` (kept), but `description` property renamed to `patternDescription` to avoid shadowing `CustomStringConvertible`.
- All types made `Sendable`.
- `TagMatcherFactory.build(from:)` returns `Result` or throws, producing clear errors for invalid regex.
- Remove `KeywordFilterResult` — not needed for this feature.

**New file:** `Sources/piqley/State/TagMatcher.swift`

**Tests:** `Tests/piqleyTests/TagMatcherTests.swift`
- Exact: case-insensitive match and non-match
- Glob: wildcard patterns, case-insensitive
- Regex: valid pattern, `wholeMatch` behavior, case-insensitive
- Factory: `regex:`, `glob:`, bare string routing
- Factory: invalid regex throws `TagMatcherError.invalidRegex`

---

## Step 2: Rule Model Types (`Sources/piqley/State/Rule.swift`)

New `Rule`, `MatchConfig`, `EmitConfig` value types. Codable, Sendable.

```swift
struct Rule: Codable, Sendable {
    let match: MatchConfig
    let emit: EmitConfig
}

struct MatchConfig: Codable, Sendable {
    let hook: String?     // defaults to "pre-process"
    let field: String     // "original:TIFF:Model"
    let pattern: String   // "regex:.*a7r.*"
}

struct EmitConfig: Codable, Sendable {
    let field: String?    // defaults to "keywords"
    let values: [String]
}
```

**New file:** `Sources/piqley/State/Rule.swift`

**Tests:** Add decode tests in `Tests/piqleyTests/RuleTests.swift`
- Full rule decodes
- Omitted `hook` decodes as nil
- Omitted `emit.field` decodes as nil

---

## Step 3: Update `PluginConfig` (`Sources/piqley/Plugins/PluginConfig.swift`)

Add `var rules: [Rule] = []` property. Since `PluginConfig` uses synthesized `Codable`, adding an optional/defaulted property requires custom `init(from:)` to handle the missing key gracefully (existing JSON files have no `rules` key).

**Tests:** Update `Tests/piqleyTests/PluginConfigTests.swift`
- Config with rules decodes correctly
- Config without rules defaults to empty array
- Save/load round-trip with rules

---

## Step 4: Update `HookConfig.command` to Optional (`Sources/piqley/Plugins/PluginManifest.swift`)

Change `let command: String` to `let command: String?` in `HookConfig`. Add custom `init(from:)` to `HookConfig` to decode `command` with `decodeIfPresent`. Update `args` to also use `decodeIfPresent` defaulting to `[]`.

**Tests:** Update `Tests/piqleyTests/PluginManifestTests.swift`
- Hook with no command decodes (empty hook entry `"pre-process": {}`)
- Existing hooks with command still decode

---

## Step 5: Add `mergeNamespace` to `StateStore` (`Sources/piqley/State/StateStore.swift`)

Add `mergeNamespace(image:plugin:values:)` method that performs field-level merge. New keys added, existing keys overwritten. Does not remove keys not present in the new values.

**Tests:** Update `Tests/piqleyTests/StateStoreTests.swift`
- `mergeNamespace` adds new fields to existing namespace
- `mergeNamespace` overwrites existing fields
- `mergeNamespace` preserves fields not in the new values
- `mergeNamespace` works when no prior namespace exists (creates it)

---

## Step 6: `RuleEvaluator` (`Sources/piqley/State/RuleEvaluator.swift`)

Core evaluation engine. Key design:

```swift
struct RuleEvaluator: Sendable {
    // Pre-compiled rules: [(rule, compiled matcher)]
    // Built once at init, reused across all images
}
```

**Init:**
- Takes `[Rule]` and validates `match.hook` against `canonicalHooks`
- Compiles patterns via `TagMatcherFactory`
- Returns errors for invalid rules (regex failures, unknown hooks)

**`evaluate(hook:state:) -> [String: JSONValue]`:**
- Filters rules by hook
- For each rule, splits `match.field` on first `:` → (namespace, field)
- Looks up value in state dict
- Matches: string → direct, array → element-wise (string elements only), other → skip
- Collects emit values per field, deduplicates preserving order
- Returns `[String: JSONValue]` (field → `.array([.string(...)])`)

**New file:** `Sources/piqley/State/RuleEvaluator.swift`

**Tests:** `Tests/piqleyTests/RuleEvaluatorTests.swift`
- Exact match on string field
- Glob match on string field
- Regex match on string field
- Array field — element-wise matching (one element matches, fires once)
- Array field — no string elements match → no output
- Non-string array elements skipped
- No match → empty output
- Multiple rules matching → additive, deduplicated
- Multiple rules emitting to different fields
- `emit.field` defaults to `"keywords"`
- Hook filtering: rule for `"post-process"` skipped at `"pre-process"`
- Hook defaulting: rule with no hook evaluates at `"pre-process"` only
- Invalid regex produces error
- Unknown hook produces error

---

## Step 7: Integrate into `PipelineOrchestrator` (`Sources/piqley/Pipeline/PipelineOrchestrator.swift`)

Modify the per-plugin-per-hook loop. After loading `PluginConfig`, before calling `PluginRunner.run`:

1. If `pluginConfig.rules` is non-empty:
   a. Build `RuleEvaluator` (once per plugin per pipeline run — but since the orchestrator processes hooks sequentially and the same plugin can appear in multiple hooks, cache the evaluator). Actually, since rules are the same across hooks, compile once when first encountered.
   b. For each image: resolve state, call `evaluator.evaluate(hook:state:)`, collect results.
   c. Write rule outputs to `StateStore` via `setNamespace`.

2. Check if `hookConfig.command` is non-nil before calling `PluginRunner.run`.
   - If nil, skip binary execution.
   - If non-nil, run binary. Use `mergeNamespace` (not `setNamespace`) to store binary results so rule outputs for other fields are preserved.

3. Handle `RuleEvaluator` init errors (invalid regex):
   - For now, log error and return critical (same as other validation failures). The `--non-interactive` flag is deferred to a follow-up (see Step 8).

**Changes:**
- Add `ruleEvaluatorCache: [String: RuleEvaluator]` as a local var in `run()`
- Guard on `hookConfig?.command != nil` before `PluginRunner.run`
- Use `mergeNamespace` for binary state results when rules also ran

**Tests:** The existing `PipelineOrchestratorTests.swift` covers the orchestrator, but those tests are integration-heavy and depend on subprocess execution. Validation of the rule→orchestrator flow is best covered by the `RuleEvaluator` unit tests plus a lightweight integration test:
- Plugin with rules only (no binary) in pipeline → outputs appear in StateStore

---

## Step 8: `--non-interactive` flag on `ProcessCommand` (`Sources/piqley/CLI/ProcessCommand.swift`)

Add `@Flag var nonInteractive = false` to `ProcessCommand`. Pass through to `PipelineOrchestrator.run()` (add parameter). When `nonInteractive` is true and a rule has an invalid regex, skip the rule and log a warning instead of aborting.

**Changes:**
- `ProcessCommand`: add flag
- `PipelineOrchestrator.run()`: add `nonInteractive: Bool = false` parameter
- `RuleEvaluator` init: accept `nonInteractive` flag, filter out bad rules with warning instead of failing

---

## Step 9: Build and test

Run `swift build` and `swift test` to verify everything compiles and passes.

---

## Execution Order

Steps 1-2 are independent (can be parallel).
Step 3 depends on Step 2 (Rule type).
Steps 4 and 5 are independent of each other, independent of 1-3.
Step 6 depends on Steps 1, 2.
Step 7 depends on Steps 3, 4, 5, 6.
Step 8 depends on Step 7.
Step 9 depends on all.
