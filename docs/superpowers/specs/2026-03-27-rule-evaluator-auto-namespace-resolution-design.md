# Rule Evaluator Auto Namespace Resolution

**Date:** 2026-03-27
**Status:** Draft

## Problem

Rules can reference foreign namespaces in match conditions and clone sources (e.g. `photo.quigs.negativelabpro.sanitizer:IPTC:Keywords`), but the state resolution at rule evaluation time only includes namespaces from the plugin manifest's `dependencies` array plus `original`, the plugin's own ID, and `skip`. If the manifest doesn't list the referenced namespace as a dependency, the resolved state omits it entirely. The match condition gets `nil`, the `guard` skips the rule, and the clone never fires. Tags (or any other cloned/matched data) silently disappear.

## Solution

Compute referenced namespaces at `RuleEvaluator` init time and expose them as a stored property. The orchestrator callsite unions these with existing dependencies when resolving state.

## Design

### RuleEvaluator: `referencedNamespaces` property

During `init`, after compiling all rules, collect namespaces into a `let referencedNamespaces: Set<String>`. Sources:

- `CompiledRule.namespace` (the match-side namespace)
- `EmitAction.clone` source namespaces (both single-field and wildcard variants)

Exclude reserved/internal values: empty strings, `"read"`, `"self"`, `"skip"`, and the plugin's own ID (since those are already handled separately by the callsite).

### Callsite: `evaluateRuleset` in `PipelineOrchestrator+Helpers`

At the `stateStore.resolve()` call (currently line 206), union `evaluator.referencedNamespaces` into the dependencies:

```swift
let ruleDeps = Array(evaluator.referencedNamespaces)
let allDeps = manifestDeps + ruleDeps + [ReservedName.original, ctx.pluginIdentifier, ReservedName.skip]
```

### No change to `buildStatePayload`

The binary's state payload is not affected. The binary already receives the plugin's own namespace (which now contains cloned data), manifest deps, and original. No current emit action besides clone references foreign namespaces, so the binary does not need foreign namespaces added to its payload.

## Testing

### Unit: RuleEvaluator.referencedNamespaces

- A rule with a cross-namespace match field (e.g. `"other.plugin:field"`) produces that namespace in `referencedNamespaces`
- A rule with a clone from a foreign namespace produces that namespace in `referencedNamespaces`
- Reserved namespaces (`"read"`, empty string, the plugin's own ID) are excluded
- A rule with only local fields produces an empty set

### Integration: evaluateRuleset resolves rule-referenced namespaces

Use an in-memory `StateStore` with data in a foreign namespace and a rule that clones from it. Assert the cloned value appears in the rule evaluation output.
