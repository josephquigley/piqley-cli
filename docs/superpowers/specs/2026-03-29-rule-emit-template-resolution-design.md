# Rule Emit Template Resolution

## Summary

Add `{{namespace:field}}` template resolution to `add` action values in declarative metadata rules. This lets rule authors reference fields from other namespaces in emitted values, e.g. `365 Project #{{photo.quigs.datetools:365_offset}}`.

Currently, the `{{namespace:field}}` template syntax is only supported in plugin environment mappings (resolved by `PluginRunner+Templates.swift`). This design extracts that logic into a shared `TemplateResolver` and integrates it into the rule evaluator for `add` actions. It also adds context-sensitive autocomplete to the rule value editor in the wizard.

## Scope

- Template resolution in `add` emit values only (not `remove`, `replace`, `removeField`, `clone`, or `skip`).
- Shared `TemplateResolver` used by both `PluginRunner` and `RuleEvaluator`.
- Wizard autocomplete triggered by `{{` in the rule value editor.

## Design

### 1. Shared TemplateResolver

A new `TemplateResolver` struct in `Sources/piqley/State/TemplateResolver.swift`.

**Responsibilities:**
- Parse `{{namespace:field}}` references in a template string.
- Resolve references against image state (`[String: [String: JSONValue]]`).
- Expand `self` to the provided `pluginId`.
- Resolve `read` namespace via `MetadataBuffer` when available.
- Fall back to colon-delimited field name lookup in the plugin's own namespace (existing behavior from `PluginRunner+Templates.swift`).
- Convert `JSONValue` to string: strings pass through, numbers format as int when whole, bools stringify, arrays join elements with commas.

**Interface:**

```swift
struct TemplateResolver: Sendable {
    func resolve(
        _ template: String,
        state: [String: [String: JSONValue]],
        metadataBuffer: MetadataBuffer?,
        imageName: String?,
        pluginId: String?,
        logger: Logger
    ) async -> String
}
```

**Migration:** `PluginRunner+Templates.swift` delegates to `TemplateResolver` for the core parsing and resolution loop. The `resolveTemplate` and `resolveFieldReference` methods become thin wrappers that pass through the plugin's identity and buffer.

### 2. RuleEvaluator Integration

In `RuleEvaluator.evaluate()`, template resolution is applied to `add` action values before `applyAction` is called.

**Flow:**
1. For each `.add(field, values)` action about to be applied, check if any value contains `{{`.
2. If so, resolve each value through `TemplateResolver.resolve()` using the current `state`, `metadataBuffer`, `imageName`, and `pluginId`.
3. Construct a new `.add(field, resolvedValues)` action and pass it to `applyAction`.

**Design decisions:**
- The `{{` check is a fast-path optimization: literal-only values (the common case) skip resolution entirely.
- `applyAction` remains a synchronous static method. Template resolution happens in the async `evaluate()` loop, producing resolved values before the synchronous apply step.
- A single `TemplateResolver` instance is created per `evaluate()` call and reused across all rules.
- When a template reference resolves to an empty string (field not found or empty), the template placeholder is replaced with an empty string. The value is still added. This matches the existing env template behavior and is logged as a warning.

### 3. Wizard Autocomplete on `{{}}`

The rule value editor switches from `promptForInput()` to `promptWithAutocomplete()` for `add` action values. Autocomplete is context-sensitive: suggestions only appear after `{{` is detected.

**Changes to `promptWithAutocomplete`:**
- New parameter: `triggerPrefix: String?` (default `nil`).
- When `triggerPrefix` is set (e.g. `"{{"`):
  - Matching uses only the substring between the last unmatched `{{` and the cursor position, not the full input.
  - When no `{{` is open (or the current template is already closed with `}}`), no suggestions are shown.
  - Tab-complete inserts `{{qualifiedName}}` at the template position, preserving text before and after.
- When `triggerPrefix` is nil, behavior is unchanged (existing full-input matching).

**Affected call sites (all for `add` action values only):**
- `RulesWizard+BuildRule.swift`: the value input loop in `promptForEmitConfig(action: "add")`.
- `RulesWizard+EditAction.swift`: `handleAddValue()` and the `.value(idx)` edit case.
- `RulesWizard+EditAction.swift`: `handleActionTypeSelection()` for the `"add"` case.

**Completions list:** Uses `buildQualifiedFieldCompletions()` already available on `RulesWizard`, which includes fields from all known namespaces with their qualified names.

**Hint text:** Updated to mention template syntax, e.g. "e.g. sony, regex:.*pattern.*, or use {{field}} for dynamic values".

## Testing

- **TemplateResolver unit tests:** Extract and adapt existing tests from `PluginRunnerEnvironmentTests.swift` to test the resolver directly. Add cases for: string values, number values, bool values, array values (comma-joined), missing fields (empty string), `read` namespace resolution, `self` expansion, mixed literal and template strings.
- **RuleEvaluator template tests:** New tests in `RuleEvaluatorTests.swift` for `add` actions with template values. Cases: single template reference, mixed literal and template, multiple templates in one value, template referencing missing field, template with `read` namespace.
- **Regression:** Existing `PluginRunnerEnvironmentTests` continue to pass after the delegation refactor.

## Out of Scope

- Template resolution in `remove`, `replace`, `removeField`, `clone`, or `skip` actions.
- Template resolution in match patterns.
- Nested template references.
