# Unconditional "Add" Rules

**Date:** 2026-03-27

## Problem

The TUI rules wizard forces every rule through a match-condition flow (pick source, pick field, enter pattern) before defining actions. For rules that should always fire (e.g., "always add `isFeatureImage=true`"), this is unnecessary friction and the "target field for add" prompt feels redundant after picking a match field.

## Design

### Data Model Changes (PiqleyCore)

**`Rule.match` becomes optional.** A nil match means the rule fires unconditionally.

- `Rule.match: MatchConfig` changes to `Rule.match: MatchConfig?`
- `Rule.init` accepts `match: MatchConfig?`
- Decoding uses `decodeIfPresent` for the `match` key
- On-disk format: unconditional rules omit the `match` key entirely

**`RuleBuilder` supports nil match.**

- `RuleBuilder.build()` no longer returns `.failure(.noMatch)` when match is nil. A nil match produces a valid unconditional rule.
- The existing `setMatch` methods remain unchanged for conditional rules.

**`RuleValidationError.noMatch` is removed** since nil match is now valid. Any code that handles this case is updated.

**`RuleValidator.validateRule`** accepts rules with nil match without error.

### Rule Evaluation Changes (piqley-cli)

**`CompiledRule` gains an unconditional variant.** When `Rule.match` is nil:

- `CompiledRule.namespace`, `field`, and `matcher` become effectively unused
- A new `unconditional: Bool` flag is added to `CompiledRule`
- During evaluation, unconditional rules skip the field-lookup and pattern-matching steps and always apply their emit/write actions

**`RuleEvaluator.init`:** When compiling a rule with nil match, skip namespace splitting, pattern compilation, and self-resolution. Set `unconditional = true`. The emit and write actions are compiled normally.

**`RuleEvaluator.evaluate`:** For unconditional rules, skip directly to applying emit and write actions (no field lookup, no pattern matching).

### Wizard Flow Changes (piqley-cli)

**New action menu as the first prompt when pressing `a` to add a rule.** The list:

```
add
add (when matching)
replace
remove from
remove field
clone
```

- **"add"**: Unconditional add. Skips match. Goes directly to `promptForEmitConfig(action: "add")` (target field + values), then the write actions prompt. Builds a `Rule` with `match: nil`.
- **"add (when matching)"**: Existing conditional flow. Prompts for match field, pattern, then emit config, then write actions.
- **"replace", "remove from", "remove field", "clone"**: Existing conditional flow (match field, pattern, then the corresponding emit config, then write actions). Display labels map to internal action names: "remove from" maps to "remove", "remove field" maps to "removeField". The others use their label as-is.

The `addActions` loop (which allowed adding multiple actions and asked "Add another action?") is replaced. The new flow adds exactly one primary action from the menu, then proceeds to write actions. If a user wants multiple emit actions on a single rule, they can add them via the edit menu after creation. This applies to both unconditional and conditional rules.

**Rule type is immutable after creation.** An unconditional rule cannot be converted to a conditional one (or vice versa) through the edit menu. The match section is either absent or present based on how the rule was created.

### Edit Menu Changes (piqley-cli)

**`EditRuleState.matchField` and `matchPattern` become optional** to represent unconditional rules.

**`buildEditRuleMenuItems`:** When match is nil (unconditional rule):
- Omit the Field, Pattern, and Negated menu items
- Show "Type: add (constant)" as the first line (read-only, non-editable)

When match is present (conditional rule): show existing menu items unchanged.

**`editRuleMenu` title:** For unconditional rules, show "Edit rule: add (constant)" instead of "Edit rule: field ~ pattern".

**`trySaveRule`:** When match fields are nil, skip match validation and build a `Rule` with `match: nil`.

### Display Changes (piqley-cli)

**`formatRule`:** For unconditional rules (nil match), display as:
```
1. (always) -> add isFeatureImage=[true]
```
instead of:
```
1. field ~ pattern -> add isFeatureImage=[true]
```

**`inspectRule`:** For unconditional rules, replace the Match section with:
```
-- Match ──────────
  (always applies)
```

### What Does NOT Change

- The edit action sub-menu (RulesWizard+EditAction.swift) is unchanged. It edits individual EmitConfig objects which are independent of whether the rule is conditional or unconditional.
- The `promptForEmitConfig` method is unchanged. It handles target field and value prompts for all action types.
- Field selection (`selectField`) is unchanged; it's just not called for unconditional rules.
- Reorder, delete, save, and inspect flows work as-is (inspect gets a minor display tweak as noted above).
