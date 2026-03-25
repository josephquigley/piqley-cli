# Rule Inspect Command Design

## Summary

Add an inspect (i) command to the rules editor TUI that displays a read-only, sectioned detail view of a selected rule's match config and all emit/write actions. The user can press 'e' to transition into the existing edit menu.

## Motivation

Currently the only way to see a rule's full details is to enter edit mode. The compact one-liner in the rule list (`field ~ pattern -> action summary`) truncates information, especially for rules with multiple actions, replacement patterns, or clone sources. An inspect view gives a quick overview without the cognitive overhead of an editable menu.

## Design

### Entry point

In `slotRuleList`, pressing 'i' on a non-deleted rule calls `inspectRule(stageName:slot:index:)`. The footer hint is updated to include `i inspect`.

### Inspect view layout

A full-screen ANSI-rendered detail view with three sections:

```
── Match ──────────────────────────────
  Field:    ISO  (original:EXIF:ISO)
  Pattern:  ^(3200|6400)$
  Negated:  no

── Emit Actions (2) ──────────────────
  1. add keywords = [High ISO, Noisy]
  2. replace title: IMG_* -> Photo_*

── Write Actions (1) ─────────────────
  1. removeField EXIF:Software

e edit  Esc back
```

### Section details

**Match section:**
- Field: short display name via `resolveFieldDisplayName`, with full qualified name in parentheses. If `resolveFieldDisplayName` returns the same value as the qualified name (fallback case), suppress the parenthetical to avoid duplication.
- Pattern: raw pattern string
- Negated: "yes" or "no" (from `match.not`)

**Emit Actions section:**
- Header shows count
- Each action on its own line, numbered, using `formatEmitAction` for the summary
- Per-action negation (`not` flag on `EmitConfig`) is shown inline as "(negated)" suffix when true
- If no emit actions: shows "(none)"

**Write Actions section:**
- Same format as emit actions
- If no write actions: shows "(none)"

### Interaction

- `e`: calls `editRuleMenu(existing:)` with the rule. If the user saves, the edit is applied to the context, `modified` is set, and the inspect view redraws with the updated rule. This means `inspectRule` loops: it fetches the rule fresh from `context.rules(forStage:slot:)` each iteration so edits are reflected.
- `Esc`: dismisses the view, returns to rule list.
- Uses plain `terminal.readKey()` (not `readKeyWithSaveTimeout`), since the inspect view has no save action.

### Keybinding note

In `slotRuleList`, both Enter and 'e' continue to go directly to edit mode. The new 'i' key is additive: inspect first, then optionally edit from within. This preserves the existing fast path for users who want to jump straight to editing.

### Guards

- Same guard as edit: skipped when the rule list is empty or the selected rule is marked for deletion.

## Implementation scope

### Files changed

1. **RulesWizard+UI.swift**: new `inspectRule(stageName:slot:index:)` method that renders the detail screen. Title shows `Rule N: field ~ pattern` for orientation.
2. **RulesWizard.swift**: add `case .char("i")` in `slotRuleList` switch, update footer string

### No changes needed

- Terminal.swift: existing ANSI primitives are sufficient
- Data models: no new types needed
- PiqleyCore: no changes
