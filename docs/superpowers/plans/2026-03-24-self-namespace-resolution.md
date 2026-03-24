# Self Namespace Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow rule fields to omit the namespace prefix or use `"self"`, resolving to the owning plugin's identifier at compile time.

**Architecture:** Add `pluginId: String?` to `RuleEvaluator.init` and `splitField`. Resolution happens once at compile time. No changes to `evaluate()` or `CompiledRule`.

**Tech Stack:** Swift 6.0, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-24-self-namespace-resolution-design.md`

---

### Task 1: Add failing tests for self namespace resolution

**Files:**
- Modify: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing tests for bare field name, `self:` prefix, skip preservation, and `self:` with nil pluginId**

Add a new `// MARK: - Self namespace resolution` section at the end of the test file with these tests:

```swift
// MARK: - Self namespace resolution

@Test("bare field name resolves to pluginId namespace")
func bareFieldResolvesToPluginId() async throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "score",
            pattern: "glob:*",
            emit: [EmitConfig(action: nil, field: "keywords", values: ["matched"], replacements: nil, source: nil)]
        )],
        pluginId: "com.example.tagger",
        logger: logger
    )
    let result = await evaluator.evaluate(
        state: ["com.example.tagger": ["score": .string("95")]]
    )
    #expect(result.namespace["keywords"] == .array([.string("matched")]))
}

@Test("self: prefix resolves to pluginId namespace")
func selfPrefixResolvesToPluginId() async throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "self:score",
            pattern: "95",
            emit: [EmitConfig(action: nil, field: "keywords", values: ["matched"], replacements: nil, source: nil)]
        )],
        pluginId: "com.example.tagger",
        logger: logger
    )
    let result = await evaluator.evaluate(
        state: ["com.example.tagger": ["score": .string("95")]]
    )
    #expect(result.namespace["keywords"] == .array([.string("matched")]))
}

@Test("bare 'skip' field preserves special behavior even with pluginId")
func bareSkipPreservesSpecialBehavior() async throws {
    // "skip" with no colon must resolve to ("", "skip"), not (pluginId, "skip")
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "skip",
            pattern: "glob:*",
            emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
        )],
        pluginId: "com.example.tagger",
        logger: logger
    )
    let skipState: [String: [String: JSONValue]] = [
        "skip": ["skip_records": .array([
            .object(["file": .string("test.jpg"), "plugin": .string("other")])
        ])]
    ]
    let result = await evaluator.evaluate(
        state: skipState,
        imageName: "test.jpg",
        pluginId: "com.example.tagger"
    )
    #expect(result.skipped)
}

@Test("bare field name with nil pluginId uses empty namespace")
func bareFieldNilPluginIdUsesEmptyNamespace() async throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "score",
            pattern: "95",
            emit: [EmitConfig(action: nil, field: "keywords", values: ["matched"], replacements: nil, source: nil)]
        )],
        pluginId: nil,
        logger: logger
    )
    let result = await evaluator.evaluate(
        state: ["": ["score": .string("95")]]
    )
    #expect(result.namespace["keywords"] == .array([.string("matched")]))
}

@Test("self: prefix with nil pluginId throws compilation error")
func selfPrefixNilPluginIdThrows() throws {
    #expect(throws: RuleCompilationError.self) {
        try RuleEvaluator(
            rules: [makeRule(field: "self:score", pattern: "95")],
            pluginId: nil,
            logger: logger
        )
    }
}

@Test("self: prefix with nil pluginId skips rule in nonInteractive mode")
func selfPrefixNilPluginIdSkipsNonInteractive() async throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(field: "self:score", pattern: "95")],
        pluginId: nil,
        nonInteractive: true,
        logger: logger
    )
    // Rule was skipped, so no compiled rules, empty result
    let result = await evaluator.evaluate(
        state: ["anything": ["score": .string("95")]]
    )
    #expect(result.namespace.isEmpty)
}

@Test("fully-qualified field still works with pluginId set")
func fullyQualifiedFieldUnchanged() async throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "original:TIFF:Model",
            pattern: "Sony",
            emit: [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]
        )],
        pluginId: "com.example.tagger",
        logger: logger
    )
    let result = await evaluator.evaluate(
        state: ["original": ["TIFF:Model": .string("Sony")]]
    )
    #expect(result.namespace["keywords"] == .array([.string("sony")]))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RuleEvaluatorTests 2>&1 | tail -20`
Expected: compilation errors because `RuleEvaluator.init` does not accept `pluginId` yet.

- [ ] **Step 3: Commit**

```
test: add failing tests for self namespace resolution
```

---

### Task 2: Implement self namespace resolution in splitField and init

**Files:**
- Modify: `Sources/piqley/State/RuleEvaluator.swift`

- [ ] **Step 1: Add `pluginId` parameter to `RuleEvaluator.init`**

Change the init signature from:

```swift
init(rules: [Rule], nonInteractive: Bool = false, logger: Logger) throws {
```

to:

```swift
init(rules: [Rule], pluginId: String? = nil, nonInteractive: Bool = false, logger: Logger) throws {
```

Store it as a local variable (not a property, since it's only needed during compilation).

- [ ] **Step 2: Update `splitField` to accept and use `pluginId`**

Replace the existing `splitField` method:

```swift
private static func splitField(_ field: String, pluginId: String? = nil) -> (namespace: String, field: String) {
    guard let colonIndex = field.firstIndex(of: ":") else {
        // Bare field name (no colon)
        if field == "skip" {
            return ("", field)
        }
        if let pluginId {
            return (pluginId, field)
        }
        return ("", field)
    }
    let namespace = String(field[field.startIndex ..< colonIndex])
    let fieldName = String(field[field.index(after: colonIndex)...])
    if namespace == "self" {
        if let pluginId {
            return (pluginId, fieldName)
        }
        return ("self", fieldName)
    }
    return (namespace, fieldName)
}
```

- [ ] **Step 3: Pass `pluginId` to the match-side `splitField` call**

In `init`, change line 52 from:

```swift
let (namespace, field) = Self.splitField(rule.match.field)
```

to:

```swift
let (namespace, field) = Self.splitField(rule.match.field, pluginId: pluginId)
```

- [ ] **Step 4: Add compilation error for `self:` with nil pluginId**

Add a new case to `RuleCompilationError`:

```swift
case unresolvedSelf(ruleIndex: Int)
```

With error description:

```swift
case let .unresolvedSelf(ruleIndex):
    "Rule \(ruleIndex): 'self' namespace requires a pluginId but none was provided"
```

Then in `init`, after the `splitField` call, add a check:

```swift
if namespace == "self" {
    let compError = RuleCompilationError.unresolvedSelf(ruleIndex: index)
    if nonInteractive {
        logger.warning("\(compError.localizedDescription) — skipping rule")
        continue
    }
    throw compError
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter RuleEvaluatorTests 2>&1 | tail -30`
Expected: all tests pass, including existing tests (since `pluginId` defaults to nil).

- [ ] **Step 6: Commit**

```
feat: resolve bare and self: namespace fields to plugin identifier
```

---

### Task 3: Pass pluginId at the call site

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift:192`

- [ ] **Step 1: Pass `ctx.pluginIdentifier` to `RuleEvaluator.init`**

Change:

```swift
evaluator = try RuleEvaluator(
    rules: rules,
    nonInteractive: ctx.nonInteractive,
    logger: logger
)
```

to:

```swift
evaluator = try RuleEvaluator(
    rules: rules,
    pluginId: ctx.pluginIdentifier,
    nonInteractive: ctx.nonInteractive,
    logger: logger
)
```

- [ ] **Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 3: Commit**

```
feat: pass pluginIdentifier to RuleEvaluator at pipeline call site
```
