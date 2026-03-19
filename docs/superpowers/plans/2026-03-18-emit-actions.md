# Emit Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add remove, replace, and removeField actions to the declarative mapping emit system.

**Architecture:** Add `Replacement` struct and `action` field to `EmitConfig` in PiqleyCore, update `Rule.emit` to an array, add `EmitAction` enum and update `RuleEvaluator` in the CLI, expand `RuleEmit`/`ConfigRule` in the SDK. TDD throughout.

**Tech Stack:** Swift 6, Swift Testing, PiqleyCore, PiqleyPluginSDK, piqley-cli

**Spec:** `docs/superpowers/specs/2026-03-18-declarative-mapping-emit-actions-design.md`

---

### Task 1: Update EmitConfig and Rule in PiqleyCore

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/Rule.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ConfigCodingTests.swift`

- [ ] **Step 1: Write failing tests for new EmitConfig shape**

Add tests to `ConfigCodingTests.swift`:

```swift
@Test func decodeEmitConfigWithAction() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": "^Draft"},
        "emit": [{"action": "remove", "field": "keywords", "values": ["draft"]}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.emit.count == 1)
    #expect(rule.emit[0].action == "remove")
    #expect(rule.emit[0].field == "keywords")
    #expect(rule.emit[0].values == ["draft"])
}

@Test func decodeEmitConfigDefaultAction() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": ".*"},
        "emit": [{"field": "keywords", "values": ["any"]}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.emit[0].action == nil)
    #expect(rule.emit[0].field == "keywords")
    #expect(rule.emit[0].values == ["any"])
}

@Test func decodeReplaceAction() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": ".*"},
        "emit": [{
            "action": "replace",
            "field": "keywords",
            "replacements": [
                {"pattern": "regex:SONY(.+)", "replacement": "Sony $1"},
                {"pattern": "old", "replacement": "new"}
            ]
        }]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.emit[0].action == "replace")
    #expect(rule.emit[0].replacements?.count == 2)
    #expect(rule.emit[0].replacements?[0].pattern == "regex:SONY(.+)")
    #expect(rule.emit[0].replacements?[0].replacement == "Sony $1")
}

@Test func decodeRemoveFieldAction() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": ".*"},
        "emit": [{"action": "removeField", "field": "*"}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.emit[0].action == "removeField")
    #expect(rule.emit[0].field == "*")
    #expect(rule.emit[0].values == nil)
}

@Test func decodeMultipleEmitActions() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": ".*"},
        "emit": [
            {"action": "removeField", "field": "keywords"},
            {"field": "keywords", "values": ["fresh"]}
        ]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.emit.count == 2)
    #expect(rule.emit[0].action == "removeField")
    #expect(rule.emit[1].action == nil)
    #expect(rule.emit[1].values == ["fresh"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

Expected: compilation errors (EmitConfig doesn't have `action`, `replacements`; Rule.emit is not an array)

- [ ] **Step 3: Update Rule.swift with new types**

Replace the contents of `Rule.swift` with:

```swift
/// Match configuration for a declarative metadata rule.
public struct MatchConfig: Codable, Sendable, Equatable {
    /// The hook this rule applies to. If nil, applies to all hooks.
    public let hook: String?
    /// The metadata field to match against.
    public let field: String
    /// The regex pattern to match against the field value.
    public let pattern: String

    public init(hook: String? = nil, field: String, pattern: String) {
        self.hook = hook
        self.field = field
        self.pattern = pattern
    }
}

/// A pattern-to-replacement mapping for the replace emit action.
public struct Replacement: Codable, Sendable, Equatable {
    /// The pattern to match. Supports glob: and regex: prefixes.
    public let pattern: String
    /// The replacement string. Supports $1/$2 capture group references for regex patterns.
    public let replacement: String

    public init(pattern: String, replacement: String) {
        self.pattern = pattern
        self.replacement = replacement
    }
}

/// Emit configuration for a declarative metadata rule.
public struct EmitConfig: Codable, Sendable, Equatable {
    /// The action to perform: "add", "remove", "replace", "removeField". Nil defaults to "add".
    public let action: String?
    /// The target field. Required. Use "*" with removeField to remove all fields.
    public let field: String
    /// Values to add or patterns to remove. Required for add and remove actions.
    public let values: [String]?
    /// Ordered pattern-to-replacement mappings for the replace action.
    public let replacements: [Replacement]?

    public init(action: String? = nil, field: String, values: [String]? = nil, replacements: [Replacement]? = nil) {
        self.action = action
        self.field = field
        self.values = values
        self.replacements = replacements
    }
}

/// A declarative metadata rule that matches a field pattern and emits operations.
public struct Rule: Codable, Sendable, Equatable {
    public let match: MatchConfig
    public let emit: [EmitConfig]

    public init(match: MatchConfig, emit: [EmitConfig]) {
        self.match = match
        self.emit = emit
    }
}
```

- [ ] **Step 4: Update existing tests to use new API**

Update existing tests in `ConfigCodingTests.swift` to use `emit` as an array and `field` as non-optional:

- `decodeRule`: change expected `rule.emit.field` to `rule.emit[0].field`, `rule.emit.values` to `rule.emit[0].values`
- `decodeMinimalRule`: update JSON to include `"field"` in emit (no longer optional), update assertions to array access
- `encodeRoundTripRule`: update `EmitConfig` construction and assertions
- `decodePluginConfigWithRules`: update JSON emit to array format, update assertions
- `encodeRoundTripPluginConfig`: update `EmitConfig` and `Rule` construction

- [ ] **Step 5: Run all PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Config/Rule.swift Tests/PiqleyCoreTests/ConfigCodingTests.swift
git commit -m "feat: add action, replacements to EmitConfig; make Rule.emit an array"
```

---

### Task 2: Update RuleEmit and ConfigRule in PiqleyPluginSDK

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/ConfigBuilderTests.swift`

- [ ] **Step 1: Write failing tests for new RuleEmit cases**

Add tests to `ConfigBuilderTests.swift`:

```swift
@Test func ruleEmitRemove() {
    let emit = RuleEmit.remove(field: "keywords", ["generic-camera", "glob:auto-*"])
    let config = emit.toEmitConfig()
    #expect(config.action == "remove")
    #expect(config.field == "keywords")
    #expect(config.values == ["generic-camera", "glob:auto-*"])
}

@Test func ruleEmitRemoveKeywords() {
    let emit = RuleEmit.removeKeywords(["old-tag"])
    let config = emit.toEmitConfig()
    #expect(config.action == "remove")
    #expect(config.field == "keywords")
    #expect(config.values == ["old-tag"])
}

@Test func ruleEmitReplace() {
    let emit = RuleEmit.replace(field: "tags", [
        (pattern: "regex:SONY(.+)", replacement: "Sony $1")
    ])
    let config = emit.toEmitConfig()
    #expect(config.action == "replace")
    #expect(config.field == "tags")
    #expect(config.replacements?.count == 1)
    #expect(config.replacements?[0].pattern == "regex:SONY(.+)")
    #expect(config.replacements?[0].replacement == "Sony $1")
}

@Test func ruleEmitReplaceKeywords() {
    let emit = RuleEmit.replaceKeywords([
        (pattern: "old", replacement: "new")
    ])
    let config = emit.toEmitConfig()
    #expect(config.action == "replace")
    #expect(config.field == "keywords")
}

@Test func ruleEmitRemoveField() {
    let emit = RuleEmit.removeField(field: "tags")
    let config = emit.toEmitConfig()
    #expect(config.action == "removeField")
    #expect(config.field == "tags")
    #expect(config.values == nil)
}

@Test func ruleEmitRemoveAllFields() {
    let emit = RuleEmit.removeAllFields
    let config = emit.toEmitConfig()
    #expect(config.action == "removeField")
    #expect(config.field == "*")
}

@Test func configRuleMultipleEmits() {
    let config = buildConfig {
        Rules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Canon")),
                emit: [
                    .removeField(field: "keywords"),
                    .values(field: "keywords", ["Canon"])
                ]
            )
        }
    }
    #expect(config.rules[0].emit.count == 2)
    #expect(config.rules[0].emit[0].action == "removeField")
    #expect(config.rules[0].emit[1].field == "keywords")
    #expect(config.rules[0].emit[1].values == ["Canon"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift && swift test --filter ConfigBuilderTests 2>&1 | tail -20`

Expected: compilation errors

- [ ] **Step 3: Update RuleEmit, ConfigRule, and toEmitConfig**

In `ConfigBuilder.swift`, update `RuleEmit`:

```swift
public enum RuleEmit: Sendable {
    case keywords([String])
    case values(field: String, [String])
    case remove(field: String, [String])
    case removeKeywords([String])
    case replace(field: String, [(pattern: String, replacement: String)])
    case replaceKeywords([(pattern: String, replacement: String)])
    case removeField(field: String)
    case removeAllFields

    func toEmitConfig() -> EmitConfig {
        switch self {
        case let .keywords(values):
            EmitConfig(field: "keywords", values: values)
        case let .values(field, values):
            EmitConfig(field: field, values: values)
        case let .remove(field, values):
            EmitConfig(action: "remove", field: field, values: values)
        case let .removeKeywords(values):
            EmitConfig(action: "remove", field: "keywords", values: values)
        case let .replace(field, pairs):
            EmitConfig(action: "replace", field: field, replacements: pairs.map { Replacement(pattern: $0.pattern, replacement: $0.replacement) })
        case let .replaceKeywords(pairs):
            EmitConfig(action: "replace", field: "keywords", replacements: pairs.map { Replacement(pattern: $0.pattern, replacement: $0.replacement) })
        case let .removeField(field):
            EmitConfig(action: "removeField", field: field)
        case .removeAllFields:
            EmitConfig(action: "removeField", field: "*")
        }
    }
}
```

Update `ConfigRule`:

```swift
public struct ConfigRule: Sendable {
    let match: RuleMatch
    let emit: [RuleEmit]

    public init(match: RuleMatch, emit: [RuleEmit]) {
        self.match = match
        self.emit = emit
    }

    func toRule() -> Rule {
        Rule(match: match.toMatchConfig(), emit: emit.map { $0.toEmitConfig() })
    }
}
```

- [ ] **Step 4: Update existing tests to use new API**

Update all existing `ConfigBuilderTests` that construct `ConfigRule` to use `emit:` as an array (wrap single emits in `[...]`). Update assertions that access `config.rules[0].emit.field` to `config.rules[0].emit[0].field`, etc. Update `ruleEmitKeywordsDefaultField` to expect `field == "keywords"` instead of `nil`.

- [ ] **Step 5: Run all SDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift
git add PiqleyPluginSDK/Builders/ConfigBuilder.swift Tests/ConfigBuilderTests.swift
git commit -m "feat: add remove, replace, removeField emit actions to RuleEmit"
```

---

### Task 3: Add regex replacement support to TagMatcher

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/TagMatcher.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/TagMatcherTests.swift`

- [ ] **Step 1: Write failing tests for replace method**

Add tests to `TagMatcherTests.swift`:

```swift
@Test("RegexMatcher replaces with capture groups")
func regexReplace() throws {
    let matcher = try RegexMatcher(pattern: "SONY(.+)")
    let result = matcher.replacing("SONYA7R5", with: "Sony $1")
    #expect(result == "Sony A7R5")
}

@Test("RegexMatcher replace no match returns original")
func regexReplaceNoMatch() throws {
    let matcher = try RegexMatcher(pattern: "SONY(.+)")
    let result = matcher.replacing("Canon", with: "Sony $1")
    #expect(result == "Canon")
}

@Test("ExactMatcher replace returns replacement on match")
func exactReplace() {
    let matcher = ExactMatcher(pattern: "old")
    let result = matcher.replacing("Old", with: "new")
    #expect(result == "new")
}

@Test("ExactMatcher replace no match returns original")
func exactReplaceNoMatch() {
    let matcher = ExactMatcher(pattern: "old")
    let result = matcher.replacing("other", with: "new")
    #expect(result == "other")
}

@Test("GlobMatcher replace returns replacement on match")
func globReplace() {
    let matcher = GlobMatcher(pattern: "SONY*")
    let result = matcher.replacing("SONYA7R5", with: "Sony Camera")
    #expect(result == "Sony Camera")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter TagMatcherTests 2>&1 | tail -20`

Expected: compilation errors (`replacing` method doesn't exist)

- [ ] **Step 3: Add replacing method to TagMatcher protocol and implementations**

In `TagMatcher.swift`, add to the protocol:

```swift
protocol TagMatcher: Sendable {
    func matches(_ value: String) -> Bool
    func replacing(_ value: String, with replacement: String) -> String
    var patternDescription: String { get }
}
```

Default implementation for non-regex matchers (match → return replacement, no match → return original):

```swift
extension TagMatcher {
    func replacing(_ value: String, with replacement: String) -> String {
        matches(value) ? replacement : value
    }
}
```

For `RegexMatcher`, override with capture group support:

```swift
func replacing(_ value: String, with replacement: String) -> String {
    guard let match = value.wholeMatch(of: regex) else { return value }
    // Build replacement string with capture group substitution
    var result = replacement
    for i in 1..<match.output.count {
        if let capture = match.output[i].substring {
            result = result.replacingOccurrences(of: "$\(i)", with: String(capture))
        }
    }
    return result
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter TagMatcherTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/TagMatcher.swift Tests/piqleyTests/TagMatcherTests.swift
git commit -m "feat: add replacing method to TagMatcher for emit replace action"
```

---

### Task 4: Update RuleEvaluator with EmitAction and new evaluate signature

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing tests for new actions**

Add tests to `RuleEvaluatorTests.swift`. First update the `makeRule` helper:

```swift
private func makeRule(
    hook: String? = nil,
    field: String = "original:TIFF:Model",
    pattern: String = "Sony",
    emit: [EmitConfig] = [EmitConfig(field: "keywords", values: ["sony"])]
) -> Rule {
    Rule(
        match: MatchConfig(hook: hook, field: field, pattern: pattern),
        emit: emit
    )
}
```

Then add new tests:

```swift
@Test("remove action filters matching values")
func removeAction() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [EmitConfig(action: "remove", field: "keywords", values: ["old-tag", "glob:auto-*"])]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["keywords": .array([.string("old-tag"), .string("auto-focus"), .string("keeper")])]
    )
    #expect(result["keywords"] == .array([.string("keeper")]))
}

@Test("replace action substitutes matching values")
func replaceAction() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1")
            ])]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["keywords": .array([.string("SONYA7R5"), .string("keeper")])]
    )
    #expect(result["keywords"] == .array([.string("Sony A7R5"), .string("keeper")]))
}

@Test("removeField action removes a field")
func removeFieldAction() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [EmitConfig(action: "removeField", field: "keywords")]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["keywords": .array([.string("old")]), "tags": .array([.string("kept")])]
    )
    #expect(result["keywords"] == nil)
    #expect(result["tags"] == .array([.string("kept")]))
}

@Test("removeField with wildcard removes all fields")
func removeFieldWildcard() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [EmitConfig(action: "removeField", field: "*")]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["keywords": .array([.string("a")]), "tags": .array([.string("b")])]
    )
    #expect(result.isEmpty)
}

@Test("multiple emit actions in one rule applied in order")
func multipleEmitActionsInOrder() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [
                EmitConfig(action: "removeField", field: "keywords"),
                EmitConfig(field: "keywords", values: ["fresh-start"])
            ]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["keywords": .array([.string("old-stuff")])]
    )
    #expect(result["keywords"] == .array([.string("fresh-start")]))
}

@Test("untouched fields preserved in output")
func untouchedFieldsPreserved() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [EmitConfig(field: "keywords", values: ["sony"])]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["existing": .string("preserved")]
    )
    #expect(result["existing"] == .string("preserved"))
    #expect(result["keywords"] == .array([.string("sony")]))
}

@Test("replace first match wins")
func replaceFirstMatchWins() throws {
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            pattern: "Sony",
            emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                Replacement(pattern: "SONYA7R5", replacement: "Sony A7R V"),
                Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1"),
            ])]
        )],
        logger: logger
    )
    let result = evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("Sony")]],
        currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
    )
    // Exact match wins over regex
    #expect(result["keywords"] == .array([.string("Sony A7R V")]))
}

@Test("invalid emit config throws in interactive mode")
func invalidEmitThrows() {
    #expect(throws: RuleCompilationError.self) {
        try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "add", field: "keywords")]
            )],
            logger: logger
        )
    }
}

@Test("replace with values present throws")
func replaceWithValuesThrows() {
    #expect(throws: RuleCompilationError.self) {
        try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", values: ["bad"], replacements: [Replacement(pattern: "a", replacement: "b")])]
            )],
            logger: logger
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests 2>&1 | tail -20`

Expected: compilation errors

- [ ] **Step 3: Update RuleEvaluator implementation**

Replace `RuleEvaluator.swift` with the new implementation:

- Add `EmitAction` enum with cases: `add`, `remove`, `replace`, `removeField`
- Add `invalidEmit(ruleIndex: Int, reason: String)` to `RuleCompilationError`
- Update `CompiledRule` to use `emitActions: [EmitAction]` instead of `emitField`/`emitValues`
- Update `init` to compile each `EmitConfig` in the `emit` array, validating constraints:
  - `add`: `values` must be non-nil and non-empty, `replacements` must be nil
  - `remove`: `values` must be non-nil and non-empty, `replacements` must be nil
  - `replace`: `replacements` must be non-nil and non-empty, `values` must be nil
  - `removeField`: `values` and `replacements` must both be nil
  - Unknown action: error
- Update `evaluate` signature to accept `currentNamespace: [String: JSONValue]` parameter
- Implement evaluation: start with mutable copy of `currentNamespace`, apply emit actions in order for each matched rule

- [ ] **Step 4: Update existing tests to use new API**

Update all existing tests in `RuleEvaluatorTests.swift`:
- Update `makeRule` helper to use new `emit: [EmitConfig]` signature
- Add `currentNamespace: [:]` parameter to all existing `evaluate` calls
- Update assertions as needed (behavior should be identical for add-only rules)

- [ ] **Step 5: Run all CLI tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/RuleEvaluator.swift Tests/piqleyTests/RuleEvaluatorTests.swift
git commit -m "feat: add remove, replace, removeField actions to RuleEvaluator"
```

---

### Task 5: Update PipelineOrchestrator caller

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`

- [ ] **Step 1: Update the evaluate call site**

In `PipelineOrchestrator.swift`, update the `evaluator.evaluate(...)` call to pass the current plugin namespace. Change:

```swift
let ruleOutput = evaluator.evaluate(hook: ctx.hook, state: resolved)
if !ruleOutput.isEmpty {
    await ctx.stateStore.mergeNamespace(
        image: imageName, plugin: ctx.pluginName, values: ruleOutput
    )
```

To:

```swift
let currentNamespace = resolved[ctx.pluginName] ?? [:]
let ruleOutput = evaluator.evaluate(hook: ctx.hook, state: resolved, currentNamespace: currentNamespace)
if ruleOutput != currentNamespace {
    await ctx.stateStore.setNamespace(
        image: imageName, plugin: ctx.pluginName, values: ruleOutput
    )
```

Note: This changes from `mergeNamespace` to `setNamespace` since the evaluator now returns the complete namespace state. If `setNamespace` doesn't exist on `StateStore`, add it (it's just a direct assignment: `images[image]![plugin] = values`).

- [ ] **Step 2: Add setNamespace to StateStore if needed**

Check if `setNamespace` exists. If not, it's already there as the existing `set` method at line 14 of `StateStore.swift`. Use whichever method does a full replacement (not merge).

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift Sources/piqley/State/StateStore.swift
git commit -m "feat: update PipelineOrchestrator to use new evaluate signature"
```

---

### Task 6: Update CLI RuleTests and PluginConfigTests

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginConfigTests.swift`

- [ ] **Step 1: Update RuleTests for new emit array format**

Update JSON in tests to use `"emit": [...]` array format and update assertions to use array indexing.

- [ ] **Step 2: Update PluginConfigTests for new format**

Update any JSON or `Rule`/`EmitConfig` construction to use the new array format.

- [ ] **Step 3: Run full CLI test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Tests/piqleyTests/RuleTests.swift Tests/piqleyTests/PluginConfigTests.swift
git commit -m "test: update RuleTests and PluginConfigTests for emit array format"
```

---

### Task 7: Update PluginCommand init examples

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/PluginCommand.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginInitTests.swift`

- [ ] **Step 1: Update ConfigRule construction in init command**

Update all `ConfigRule(...)` calls in `PluginCommand.swift` to use `emit: [...]` array syntax. The existing examples use single `emit:` values — wrap each in an array.

Also add one example using the new actions to demonstrate the feature:

```swift
ConfigRule(
    match: .field(
        .dependency(name, key: "tags"),
        pattern: .exact("Kodak"),
        hook: .postProcess
    ),
    emit: [
        .remove(field: "tags", ["Kodak"]),
        .values(field: "tags", ["Kodak Film"])
    ]
)
```

- [ ] **Step 2: Update PluginInitTests if they assert on emit format**

Update any test assertions that check the generated config JSON to expect the new array format.

- [ ] **Step 3: Run full CLI test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/CLI/PluginCommand.swift Tests/piqleyTests/PluginInitTests.swift
git commit -m "feat: update plugin init examples with new emit actions"
```

---

### Task 8: Final cross-repo verification

- [ ] **Step 1: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

- [ ] **Step 2: Run PiqleyPluginSDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift && swift test 2>&1 | tail -20`

- [ ] **Step 3: Run piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`

- [ ] **Step 4: Build release**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build -c release 2>&1 | tail -10`

Expected: all pass, clean build
