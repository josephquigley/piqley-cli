# Implementation Plan: Auto-Clone on Empty Remove/Replace

**Spec:** `docs/superpowers/specs/2026-03-26-auto-clone-on-empty-remove-replace-design.md`

## Steps

### 1. Add auto-clone logic in `RuleEvaluator.evaluate()`

**File:** `Sources/piqley/State/RuleEvaluator.swift`

In the emit action loop (around line 277, before `Self.applyAction(action, to: &working)`), add a check: if the action is `.remove` or `.replace`, and the target field doesn't exist in `working`, clone it from `state[rule.namespace]`.

```swift
// Before applyAction, auto-clone for remove/replace on empty fields
switch action {
case let .remove(field, _, _), let .replace(field, _):
    if working[field] == nil, let source = state[rule.namespace]?[field] {
        working[field] = source
    }
default:
    break
}
```

### 2. Add tests

**File:** `Tests/piqleyTests/RuleEvaluatorTests.swift`

Add tests:
- `testRemoveAutoCloneFromSource`: remove on empty working, field exists in match namespace. Verify values are cloned then filtered.
- `testRemoveNoAutoCloneWhenFieldExists`: remove on populated working. Verify no clone, existing behavior.
- `testRemoveNoAutoCloneWhenSourceMissing`: remove on empty working, field missing from source. Verify no-op.
- `testReplaceAutoCloneFromSource`: replace on empty working, field exists in match namespace.
- `testAddNoAutoClone`: add on empty working. Verify field created with only specified values (no clone).

### 3. Build and run tests

Verify all existing tests still pass and new tests pass.
