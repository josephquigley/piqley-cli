# Rule Edit Menu Design

**Date:** 2026-03-22
**Scope:** CLI rule editor wizard UX improvement

## Problem

When editing an existing rule in the TUI wizard, the user is forced through the same sequential flow as creating a new rule (source -> field -> pattern -> actions). This overwrites fields before the user can reach later ones. There is no way to edit a single component of an existing rule without re-entering everything.

## Solution

When editing an existing rule, show a navigable menu of the rule's components. The user selects which component to edit individually. The new-rule flow remains sequential.

## Approach

Top-level menu with action sub-menus (Approach 1 from brainstorming). Uses existing TUI primitives (`drawScreen`, `promptForInput`, `promptWithAutocomplete`, `selectFromList`). No new terminal components needed.

## Top-Level Edit Rule Menu

When `editRule` is called on an existing rule, display:

```
Edit rule: EXIF:Make ~ glob:Sony*
----------------------------------
  Field: EXIF:Make
  Pattern: glob:Sony*
  Negated: no
  add keywords=[sony, alpha]
  replace Make [Son*->Sony]
  write: removeField GPS:*
  + Add action
  + Add write action
  Save

up/down navigate  Enter edit  d delete  Esc cancel
```

Menu items and behavior:

- **Field**: opens source -> field selection (reused from existing flow). Updates match field only.
- **Pattern**: opens `promptForInput` with current pattern as `defaultValue`.
- **Negated**: toggles `MatchConfig.not` between true/false on Enter (no sub-screen needed).
- **Action lines**: opens the action sub-menu (see below). Emit actions are shown plain, write actions are prefixed with `write:` to distinguish them visually.
- **+ Add action / + Add write action**: runs action type selection -> `promptForEmitConfig`, appends result.
- **d key** on an action line: removes that action.
- **Save**: validates via `RuleBuilder`, returns the rule. Shows validation errors if invalid.
- **Esc**: cancels, returns nil (no changes).

State is maintained as mutable local variables (`matchField`, `matchPattern`, `matchNot`, `emitActions: [EmitConfig]`, `writeActions: [EmitConfig]`) derived from the existing rule. On Save, these are fed through `RuleBuilder` for validation.

Since `EmitConfig` uses `let` properties, each edit in the action sub-menu constructs a new `EmitConfig` instance rather than mutating in place.

## Action Sub-Menu

Selecting an existing action opens a sub-menu adapted to the action type.

### add/remove

```
Edit action: add keywords
---------------------------
  Type: add
  Field: keywords
  Negated: no
  Value: sony
  Value: alpha
  + Add value
  Done

up/down navigate  Enter edit  d delete value  Esc back
```

### replace

```
Edit action: replace Make
--------------------------
  Type: replace
  Field: Make
  Negated: no
  Pattern: Son*
  Replacement: Sony
  Done

up/down navigate  Enter edit  Esc back
```

### clone

```
Edit action: clone keywords
-----------------------------
  Type: clone
  Field: keywords
  Negated: no
  Source: original:IPTC:Keywords
  Done

up/down navigate  Enter edit  Esc back
```

### removeField

```
Edit action: removeField GPS:*
--------------------------------
  Type: removeField
  Field: GPS:*
  Negated: no
  Done

up/down navigate  Enter edit  Esc back
```

### Sub-menu behavior

- **Type**: shows action type list (add/remove/replace/removeField/clone). If type changes, action-specific fields (values, replacements, source) are cleared and the user is prompted for them immediately.
- **Field**: opens `promptWithAutocomplete` with current field as `defaultValue`.
- **Negated**: toggles `EmitConfig.not` between true/false on Enter.
- **Value items** (add/remove): selecting opens `promptForInput` with current value as `defaultValue`.
- **+ Add value**: prompts for a new value, appends it.
- **d key** on a value: removes that value.
- **Pattern/Replacement** (replace): each opens `promptForInput` with current as default.
- **Source** (clone): opens `promptForInput` with current as default.
- **Done**: validates the action via `RuleValidator.validateEmit` before returning. Shows error and stays in the sub-menu if invalid. Returns the modified `EmitConfig` to the top-level menu on success.
- **Esc**: discards changes to this action, returns to top-level unchanged.

Each edit constructs a new `EmitConfig` instance since the type uses immutable `let` properties.

## Files Changed

**RulesWizard.swift** (CLI):
- Add `editRuleMenu(existing:) -> Rule?`: top-level edit menu
- Add `editAction(_ config: EmitConfig) -> EmitConfig?`: action sub-menu
- Add `selectField() -> (qualifiedName: String, displayName: String)?`: extracted from inline source -> field selection in `buildRule`
- Modify `buildRule(editing:)`: call `editRuleMenu` when `existing` is non-nil

**RulesWizard+UI.swift** (CLI):
- Add `formatEmitAction(_ emit: EmitConfig) -> String`: action summary formatting (alongside existing `formatRule`)

**PiqleyCore - RuleBuilder**: Add `setMatch(field:pattern:not:)` overload to support the negation flag. The existing `setMatch(field:pattern:)` continues to work for the new-rule flow. No other PiqleyCore changes needed.

## What stays the same

- New rule flow (`addRule` -> `buildRule(editing: nil)`) remains sequential
- Rule list screen, reorder, delete, save/quit flows unchanged
- All validation still goes through `RuleBuilder` and `RuleValidator`
