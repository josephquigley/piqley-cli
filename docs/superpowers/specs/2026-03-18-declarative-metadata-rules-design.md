# Declarative Metadata Rules Design

**Status:** Approved

## Overview

Add declarative rule evaluation to the plugin system so that plugins can match metadata fields against patterns and emit keywords (or other values) without a custom binary. Rules live in the plugin's `config.json` and are evaluated by piqley core before the hook binary runs. A plugin with rules and no binary is a fully declarative plugin — no executable needed.

This restores the keyword-mapping capability from the pre-plugin architecture (the old `TagMatcher` / `matchingCameraTags` code) as a native feature of the plugin system.

---

## Section 1: Rule Evaluation in the Plugin Lifecycle

At each hook stage, before running the hook binary, `PipelineOrchestrator` evaluates any rules from the plugin's `config.json` whose `match.hook` field matches the current stage. Rule outputs are written to the plugin's namespace in `StateStore`. Then the binary runs (if one exists) and can read/overwrite those values.

If there's no binary for the current hook and no rules match the current stage, execution is a no-op for that hook.

**Per-rule hook scoping:** Each rule has an optional `match.hook` field (defaults to `"pre-process"`). Rules are only evaluated when the current pipeline stage matches. A single plugin can have rules targeting different stages.

**Evaluation order:** Rules are evaluated in array order, per-image. All matching rules contribute additively (union, deduplicated) to their respective `emit.field`.

**No binary required:** If a plugin has no hook binary, rule evaluation is the entire execution for that stage. The plugin still participates in the pipeline — it has a namespace, its outputs feed into downstream dependents, and other plugins can depend on it.

**Pipeline entry for rules-only plugins:** Today, `PluginDiscovery.autoAppend()` only adds a plugin to a hook's pipeline if `manifest.hooks[hookName]` exists, and `PluginRunner` treats a missing hook config as a critical failure. To support rules-only plugins, `HookConfig.command` becomes optional. A rules-only plugin declares hook participation with an empty hook entry in its manifest (e.g., `"pre-process": {}`), which signals "I participate in this stage but have no binary." The orchestrator checks for a non-nil `command` before calling `PluginRunner`. This also enables hybrid plugins to declare hook stages where they only contribute rules.

---

## Section 2: Rule Schema

Rules live in the plugin's `config.json` under a top-level `"rules"` key.

```json
{
  "rules": [
    {
      "match": {
        "hook": "post-process",
        "field": "original:TIFF:Model",
        "pattern": "regex:.*a7r.*"
      },
      "emit": {
        "field": "keywords",
        "values": ["Sony", "Shot on Sony", "A7R Life"]
      }
    },
    {
      "match": {
        "field": "original:EXIF:LensModel",
        "pattern": "RF 24-70mm F2.8L"
      },
      "emit": {
        "values": ["Canon RF", "24-70 Gang"]
      }
    },
    {
      "match": {
        "field": "original:IPTC:Keywords",
        "pattern": "glob:*Cats*"
      },
      "emit": {
        "field": "keywords",
        "values": ["Cat Photography", "Feline"]
      }
    }
  ],
  "values": {}
}
```

Note: The second rule above omits `match.hook` (defaults to `"pre-process"`) and `emit.field` (defaults to `"keywords"`).

### `match` object

- `hook` (string, optional) — Pipeline stage to evaluate at. Defaults to `"pre-process"`. Must be one of the 5 canonical hooks: `pre-process`, `post-process`, `publish`, `schedule`, `post-publish`.
- `field` (string, required) — Namespaced field to match against: `"original:<tag>"` for extracted metadata, or `"<plugin-name>:<field>"` for another plugin's output. The referenced plugin must be declared in the manifest's `dependencies` (except `original`, which is always available).
- `pattern` (string, required) — Uses the existing prefix convention: `"regex:..."` for regex, `"glob:..."` for fnmatch-style glob, or a bare string for exact match. All matching is case-insensitive.

### `emit` object

- `field` (string, optional) — Field name written to the plugin's namespace. Defaults to `"keywords"`.
- `values` (array of strings, required) — Values to emit when the rule matches.

### Array fields

When the matched field contains an array (e.g. `IPTC:Keywords`), each element is tested individually against the pattern. Only string elements are tested — non-string elements (numbers, bools, nulls, nested objects) are skipped. If any string element matches, the rule fires once — no duplicate emissions regardless of how many elements match.

### Coexistence with existing config

`rules` sits alongside the existing `values` and `isSetUp` keys in `config.json`. The `PluginConfig` model gains a `rules: [Rule]` property, defaulting to an empty array.

---

## Section 3: Rule Evaluation Engine

A new internal type `RuleEvaluator` handles matching and emission. It lives in `Sources/piqley/State/` alongside the existing `StateStore` and `MetadataExtractor`.

### Initialization (once per pipeline run)

1. Check the plugin against `PluginBlocklist`. If blocklisted, skip rule compilation and evaluation entirely — same as the existing binary skip behavior.
2. Parse all rules from the plugin's `config.json`.
3. For each rule, compile the pattern into a matcher (`ExactMatcher`, `GlobMatcher`, or `RegexMatcher`). Compiled matchers are cached — one compilation per rule for the entire pipeline run.
4. Validate that referenced namespaces are in the plugin's declared dependencies (or `original`). Fail fast if not.
5. If any regex fails to compile:
   - **Interactive mode (default):** Report the bad pattern(s) and prompt the user: "Rule N has invalid regex `<pattern>`: `<error>`. Continue without this rule? [y/N]"
   - **`--non-interactive` mode:** Drop the invalid rule, log a warning, continue with remaining rules.
   - In both modes, the bad rule is removed from the evaluated set — never silently produces wrong results.

### Per-image evaluation

1. Filter cached rules to those matching the current hook stage.
2. For each rule, look up `match.field` in the resolved state (split on first `:` to get namespace and field name).
3. Match the field value using the pre-compiled matcher:
   - **String value:** Test directly.
   - **Array value:** Test each element; fire if any matches.
   - **Number/bool/null/object:** Skip (no match).
4. If matched, collect `emit.values` under `emit.field` (defaulting to `"keywords"`).
5. After all rules: merge per-field, deduplicate, preserving array order (first occurrence wins).

### Output

A `[String: JSONValue]` dictionary written to the plugin's namespace via `StateStore.setNamespace` (wholesale write — this is the first write for this plugin at this hook stage). If a binary runs afterward, its outputs are layered on top via `mergeNamespace` (see Section 4). Array fields are stored as `JSONValue.array([.string(...)])`.

### Pattern parsing

Reuses the `regex:` / `glob:` / exact prefix convention from the old `TagMatcherFactory`. The matcher types (`ExactMatcher`, `GlobMatcher`, `RegexMatcher`) are brought back from `_migrate/ImageProcessing/TagMatcher.swift` into `Sources/piqley/State/` as internal types, cleaned up to conform to `Sendable`.

---

## Section 4: Integration with PipelineOrchestrator

Today the orchestrator loop per hook is: resolve dependencies → run binary → store results. The change inserts rule evaluation before the binary.

### Revised per-plugin hook execution

1. **Check `PluginBlocklist`** — if blocklisted, skip entirely (unchanged).
2. **Resolve state** from `StateStore` for declared dependencies + `original`.
3. **Evaluate rules** — `RuleEvaluator` processes rules matching the current hook, writes results to plugin namespace.
4. **Run hook binary** (if declared) — binary receives the updated state (including rule outputs) in its JSON payload.
5. **Store binary results** — binary output merges with/overwrites rule outputs in the plugin's namespace.

### No binary case

Steps 4-5 are skipped. Rule outputs are the final state for this plugin at this hook stage.

### Binary + rules case

The binary sees rule outputs as part of its resolved state (under its own namespace). If the binary returns values for the same field, the binary wins — it's the later writer. This is implemented as a field-level merge: after the binary completes, its output dictionary is merged on top of the rule output dictionary. Binary values overwrite rule values per-field; rule-only fields survive.

### State merge semantics

Today `StateStore.setNamespace` does a wholesale replacement of the plugin's namespace. This must change to support the rules-then-binary flow. A new `mergeNamespace(image:plugin:values:)` method performs field-level merge — new keys are added, existing keys are overwritten. The orchestrator calls `setNamespace` for rule outputs, then `mergeNamespace` for binary outputs (if any).

### Dependency validation

Existing `DependencyValidator` needs no changes. Rule field references use the same namespace model. The validator already checks that declared dependencies exist and run earlier. Note: this depends on rules-only plugins being discoverable into the pipeline (see Section 1, "Pipeline entry for rules-only plugins").

---

## Section 5: Changes to Existing Types

### Modified types

**`PluginConfig`** (`Sources/piqley/Plugins/PluginConfig.swift`) — Gains a `rules: [Rule]` property, decoded from `config.json`. Defaults to empty array. Decode failures for the `rules` key should surface as warnings (not silently swallowed), since `PluginConfig.load(fromIfExists:)` currently uses `try?`.

**`PluginManifest.HookConfig`** (`Sources/piqley/Plugins/PluginManifest.swift`) — `command` becomes `String?` (optional). A nil command means the plugin participates in this hook stage but has no binary.

**`ProcessCommand`** (`Sources/piqley/CLI/`) — Gains `--non-interactive` flag. Passed through to `PipelineOrchestrator`.

**`PipelineOrchestrator`** (`Sources/piqley/Pipeline/PipelineOrchestrator.swift`) — Accepts `nonInteractive: Bool`. Before each binary invocation, calls `RuleEvaluator` for the current plugin/hook. Writes rule outputs to `StateStore` before running the binary. Checks for non-nil `hookConfig.command` before calling `PluginRunner`.

**`StateStore`** (`Sources/piqley/State/StateStore.swift`) — Gains a `mergeNamespace(image:plugin:values:)` method that performs field-level merge (new keys added, existing keys overwritten). Used by the orchestrator to layer binary outputs on top of rule outputs.

### New types

- **`RuleEvaluator`** — In `Sources/piqley/State/`. Holds pre-compiled matchers per plugin. Evaluates rules against resolved state per image. Validates `match.hook` values against `canonicalHooks` at compile time.
- **`Rule`, `MatchConfig`, `EmitConfig`** — Value types for the rule schema. Codable, Sendable.
- **`ExactMatcher`, `GlobMatcher`, `RegexMatcher`** — Brought back from `_migrate/ImageProcessing/TagMatcher.swift` into `Sources/piqley/State/`. Cleaned up to conform to `Sendable`. `TagMatcher` protocol's `description` property renamed to `patternDescription` to avoid shadowing `CustomStringConvertible`.

### No changes to

- `PluginRunner` — binary execution is unchanged. The orchestrator gates the call on a non-nil `hookConfig.command` before invoking `PluginRunner.run`, so the runner never receives a nil command. No changes to `PluginRunner` internals or `resolveExecutable` are needed.
- `PluginDiscovery` — plugin loading unchanged. Rules-only plugins use empty hook entries in the manifest (e.g., `"pre-process": {}`), which `autoAppend` already handles since it checks `hooks[hookName] != nil`. Note: since `HookConfig.command` becomes `String?`, the synthesized `Codable` conformance will handle the absent key via `decodeIfPresent` automatically.
- `DependencyValidator` — namespace model unchanged.

---

## Section 6: Testing Strategy

### Unit tests for `RuleEvaluator`

- Exact match on string field.
- Glob match on string field.
- Regex match on string field.
- Array field — element-wise matching (match on one element, no match on none).
- No match — rule doesn't fire, no output.
- Multiple rules matching same image — additive, deduplicated.
- Multiple rules emitting to different fields.
- `emit.field` defaults to `"keywords"` when omitted.
- Hook filtering — rule with `hook: "post-process"` skipped during `pre-process`.
- Hook defaulting — rule with no `hook` evaluates during `pre-process` only.
- Invalid regex — produces error for interactive handling.
- Blocklisted plugin — rules not compiled or evaluated.

### Unit tests for matchers

Port and update existing matcher logic from `_migrate/`. Cover: case insensitivity, glob wildcards, regex anchoring (`wholeMatch` behavior).

### Integration test with `PipelineOrchestrator`

- Plugin with rules only (no binary) — outputs appear in `StateStore`.
- Plugin with rules + binary — binary receives rule outputs, binary output overwrites rule output for same field.
- Plugin referencing another plugin's namespace — dependency ordering respected.

### `--non-interactive` flag

- Bad regex in non-interactive mode — rule dropped, warning logged, pipeline continues.
- Bad regex in interactive mode — tested via prompt mock or by verifying the error is surfaced.
