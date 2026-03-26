# Auto-Clone on Empty Field for Remove and Replace Actions

**Date:** 2026-03-26

## Problem

When a rule's `remove` or `replace` emit action targets a field that doesn't exist in the plugin's working namespace, the action is silently a no-op. This is a common footgun: users write a rule that matches `original:IPTC:Keywords` and emits a `remove` on `IPTC:Keywords`, expecting it to filter the original values. Instead, nothing happens because the plugin's namespace is empty.

The current workaround is to add an explicit `clone` action before the `remove`/`replace`, but this isn't intuitive and the silent no-op gives no indication that anything is wrong.

## Design

When `remove` or `replace` targets a field that doesn't exist in the working namespace, automatically clone the same-named field from the match rule's source namespace before applying the action.

### Logic

For `remove` and `replace` emit actions:

1. Look up the target `field` in the working namespace.
2. **If it exists:** apply the action as-is (no behavior change).
3. **If it doesn't exist:** look up `field` in the match rule's source namespace (e.g., `original` when the match field is `original:IPTC:Keywords`).
4. **If found in source:** clone the value into the working namespace, then apply the action.
5. **If not found in source either:** no-op (same as current behavior).

### What doesn't change

- `add` keeps current behavior. Adding to an empty field creates the field with the specified values, which is already useful and intuitive.
- `clone` remains available for cross-field or cross-namespace copies where the field names differ.
- Namespace isolation is preserved. The auto-clone copies data into the plugin's namespace; it never modifies the source namespace.
- If the target field already exists in the working namespace, no clone happens.

### Where the change lives

`RuleEvaluator.evaluate()` in `Sources/piqley/State/RuleEvaluator.swift`. The auto-clone must happen before `applyAction` is called, since `applyAction` is a static method that only sees the working namespace. The `evaluate()` method already has access to the resolved `state` (all namespaces) and the compiled rule's `namespace` field (the match source namespace).

For each `remove` or `replace` emit action, before calling `applyAction`:

1. Check if `working[action.field]` is nil.
2. If nil, check `state[rule.namespace]?[action.field]`.
3. If found, set `working[action.field]` to that value.

This keeps `applyAction` unchanged and localizes the new behavior to the evaluation loop.

**`read:` namespace limitation:** When the match namespace is `read:`, field values come from the MetadataBuffer, not from the `state` dictionary. Auto-clone via `state[rule.namespace]` won't find them. Rules matching on `read:` fields that need remove/replace must still use an explicit `clone` action. This is an uncommon combination and not worth special-casing.

### Example

Current stage config (no changes needed):

```json
{
  "preRules": [
    {
      "match": {
        "field": "original:IPTC:Keywords",
        "pattern": "glob:*"
      },
      "emit": [
        {
          "action": "remove",
          "field": "IPTC:Keywords",
          "values": ["Developer", "Dilution", "Format"]
        }
      ]
    }
  ]
}
```

Before this change: remove finds nothing in the empty working namespace. After: the evaluator clones `original`'s `IPTC:Keywords` into working, then removes the matched values.

## Testing

- **Empty working, field exists in source:** auto-clones and removes/replaces correctly.
- **Field already in working:** no clone, existing behavior preserved.
- **Field missing from both working and source:** no-op, no crash.
- **`add` action on empty field:** no auto-clone, creates field with specified values (unchanged).
- **`replace` on empty working, field in source:** auto-clones and replaces correctly.
- **Multiple emit actions in same rule:** auto-clone happens per-action, so a rule with clone + remove still works (clone populates field, remove sees it exists and skips auto-clone).
