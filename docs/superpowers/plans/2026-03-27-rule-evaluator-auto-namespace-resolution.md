# Rule Evaluator Auto Namespace Resolution - Implementation Plan

**Spec:** `docs/superpowers/specs/2026-03-27-rule-evaluator-auto-namespace-resolution-design.md`

## Steps

### Step 1: Add `referencedNamespaces` property to RuleEvaluator

**File:** `Sources/piqley/State/RuleEvaluator.swift`

- Add `let referencedNamespaces: Set<String>` property to `RuleEvaluator`
- In `init`, after compiling all rules, walk `compiledRules` to collect:
  - Each `CompiledRule.namespace` (match-side)
  - Each `EmitAction.clone` `sourceNamespace` (from both emit and write actions)
- Filter out reserved values: empty strings, `"read"`, `"self"`, `"skip"`, and `pluginId` (when non-nil)
- Store the filtered set

### Step 2: Update `evaluateRuleset` to use `referencedNamespaces`

**File:** `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`

- After obtaining the evaluator (line ~192), read `evaluator.referencedNamespaces`
- Union it into the dependencies array passed to `stateStore.resolve()` (line ~206)

### Step 3: Unit tests for `referencedNamespaces`

**File:** `Tests/piqleyTests/State/RuleEvaluatorTests.swift` (or new file if needed)

Test cases:
- Cross-namespace match field populates `referencedNamespaces`
- Clone from foreign namespace populates `referencedNamespaces`
- Reserved namespaces (`"read"`, empty, plugin's own ID) are excluded
- Local-only rules produce empty set
- Wildcard clone source namespace is included

### Step 4: Integration test for evaluateRuleset

**File:** `Tests/piqleyTests/Pipeline/` (find existing orchestrator test file or create)

- Set up an in-memory `StateStore` with data under a foreign namespace
- Define a rule that clones from that foreign namespace
- Call `evaluateRuleset` with empty `manifestDeps`
- Assert the cloned value appears in the output namespace

### Step 5: Build and run tests

- `swift build`
- `swift test`
- Verify all pass
