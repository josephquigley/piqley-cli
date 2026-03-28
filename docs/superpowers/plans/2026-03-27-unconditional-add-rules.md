# Unconditional Add Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support unconditional rules (no match condition) so the wizard can add constant field values without requiring a match pattern.

**Architecture:** Make `Rule.match` optional in PiqleyCore (nil = always fires). Update RuleBuilder to allow nil match. Update RuleEvaluator to skip pattern matching for unconditional rules. Restructure the wizard's "add rule" flow to present action-type selection first, with "add" being unconditional and "add (when matching)" preserving the existing conditional flow.

**Tech Stack:** Swift 6, PiqleyCore (separate repo), piqley-cli, Swift Testing framework

**Repos:**
- PiqleyCore: `/Users/wash/Developer/tools/piqley/piqley-core`
- piqley-cli: `/Users/wash/Developer/tools/piqley/piqley-cli`

---

## Task 1: Make Rule.match optional (PiqleyCore)

**Repo:** piqley-core
**Files:**
- Modify: `Sources/PiqleyCore/Config/Rule.swift`
- Modify: `Sources/PiqleyCore/RuleEditing/RuleBuilder.swift`
- Modify: `Sources/PiqleyCore/Validation/RuleValidationError.swift`
- Test: `Tests/PiqleyCoreTests/RuleBuilderTests.swift`
- Test: `Tests/PiqleyCoreTests/ConfigCodingTests.swift`

- [ ] **Step 1: Write failing test for unconditional rule building**

In `Tests/PiqleyCoreTests/RuleBuilderTests.swift`, add:

```swift
@Test func buildWithoutMatchSucceedsForUnconditionalRule() {
    var builder = RuleBuilder(context: makeContext())
    _ = builder.addEmit(makeEmit())
    let result = builder.build()
    if case .success(let rule) = result {
        #expect(rule.match == nil)
        #expect(rule.emit.count == 1)
    } else {
        Issue.record("Expected .success for unconditional rule, got \(result)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleBuilderTests/buildWithoutMatchSucceedsForUnconditionalRule 2>&1 | tail -20`
Expected: FAIL (currently returns `.failure(.noMatch)`)

- [ ] **Step 3: Write failing test for unconditional rule decoding**

In `Tests/PiqleyCoreTests/ConfigCodingTests.swift`, add:

```swift
@Test func decodeUnconditionalRule() throws {
    let json = """
    {
        "emit": [{"action": "add", "field": "isFeatureImage", "values": ["true"]}]
    }
    """
    let rule = try JSONDecoder.piqley.decode(Rule.self, from: Data(json.utf8))
    #expect(rule.match == nil)
    #expect(rule.emit[0].field == "isFeatureImage")
    #expect(rule.emit[0].values == ["true"])
}

@Test func encodeRoundTripUnconditionalRule() throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(action: "add", field: "isFeatureImage", values: ["true"], replacements: nil, source: nil)]
    )
    let data = try JSONEncoder.piqley.encode(rule)
    let decoded = try JSONDecoder.piqley.decode(Rule.self, from: data)
    #expect(decoded.match == nil)
    #expect(decoded.emit[0].field == "isFeatureImage")
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests/decodeUnconditionalRule 2>&1 | tail -20`
Expected: FAIL (decoder requires `match` key)

- [ ] **Step 5: Make Rule.match optional**

In `Sources/PiqleyCore/Config/Rule.swift`, change `Rule`:

```swift
public struct Rule: Codable, Sendable, Equatable {
    public let match: MatchConfig?
    public let emit: [EmitConfig]
    public let write: [EmitConfig]

    public init(match: MatchConfig?, emit: [EmitConfig], write: [EmitConfig] = []) {
        self.match = match
        self.emit = emit
        self.write = write
    }

    private enum CodingKeys: String, CodingKey {
        case match, emit, write
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decodeIfPresent(MatchConfig.self, forKey: .match)
        emit = try container.decode([EmitConfig].self, forKey: .emit)
        write = try container.decodeIfPresent([EmitConfig].self, forKey: .write) ?? []
    }
}
```

- [ ] **Step 6: Remove .noMatch error case and update RuleBuilder**

In `Sources/PiqleyCore/Validation/RuleValidationError.swift`, remove the `noMatch` case entirely: remove it from the enum, its `errorDescription`, its `recoverySuggestion`, and its `==` implementation.

In `Sources/PiqleyCore/RuleEditing/RuleBuilder.swift`, update `build()`:

```swift
public func build() -> Result<Rule, RuleValidationError> {
    guard !emitActions.isEmpty || !writeActions.isEmpty else {
        return .failure(.noActions)
    }
    return .success(Rule(match: match, emit: emitActions, write: writeActions))
}
```

Also update `reset()` since the `noMatch` error is gone, the test `resetClearsAllState` will need to check for `.noActions` instead (no match + no actions = `.noActions`).

- [ ] **Step 7: Fix existing tests that reference .noMatch**

In `Tests/PiqleyCoreTests/RuleBuilderTests.swift`:

Update `buildWithoutMatchFailsNoMatch` to become `buildWithoutMatchOrActionsFailsNoActions`:

```swift
@Test func buildWithoutMatchOrActionsFailsNoActions() {
    var builder = RuleBuilder(context: makeContext())
    let result = builder.build()
    #expect(isBuildFailure(result, .noActions))
}
```

Update `setMatchDoesNotStoreOnValidationFailure`: the build now fails with `.noActions` (not `.noMatch`) since without a valid match set the match stays nil, but it has an emit action, so it would actually succeed as unconditional. Update to reflect new behavior:

```swift
@Test func setMatchDoesNotStoreOnValidationFailure() {
    var builder = RuleBuilder(context: makeContext())
    _ = builder.setMatch(field: "", pattern: "portrait")
    _ = builder.addEmit(makeEmit())

    let buildResult = builder.build()
    // Match validation failed, so match is still nil.
    // Build succeeds as an unconditional rule.
    if case .success(let rule) = buildResult {
        #expect(rule.match == nil)
    } else {
        Issue.record("Expected .success (unconditional), got \(buildResult)")
    }
}
```

Update `resetClearsAllState`:

```swift
@Test func resetClearsAllState() {
    var builder = RuleBuilder(context: makeContext())
    _ = builder.setMatch(field: "Keywords", pattern: "portrait")
    _ = builder.addEmit(makeEmit())
    _ = builder.addWrite(makeEmit(action: "removeField", field: "ISO", values: nil))

    builder.reset()

    let result = builder.build()
    #expect(isBuildFailure(result, .noActions))
}
```

- [ ] **Step 8: Fix existing tests that access rule.match non-optionally**

In `Tests/PiqleyCoreTests/RuleBuilderTests.swift`, update all `rule.match.field` and `rule.match.pattern` accesses to use optional chaining or force-unwrap where the test guarantees a match exists:

- `fullBuildFlowEmitSucceeds`: `rule.match?.field` and `rule.match?.pattern`
- `fullBuildFlowWithEmitAndWrite`: `rule.match?.field`
- `setMatchReplacesExistingMatch`: `rule.match?.field`
- `setMatchWithNotFlagPreservesNegation`: `rule.match?.not`
- `setMatchWithNotNilOmitsFlag`: `rule.match?.not`

In `Tests/PiqleyCoreTests/ConfigCodingTests.swift`, update:
- `decodeRule`: `rule.match?.field`, `rule.match?.pattern`
- `decodeMinimalRule`: `rule.match?.field`, `rule.match?.pattern`
- `encodeRoundTripRule`: `decoded.match?.field`, `decoded.match?.pattern`

- [ ] **Step 9: Run all PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 10: Commit**

```
feat: make Rule.match optional to support unconditional rules

A nil match means the rule fires unconditionally, enabling
"always add" rules that don't require a match condition.
```

## Task 2: Tag and release PiqleyCore, update piqley-plugin-sdk dependency

**Repos:** piqley-core, piqley-plugin-sdk, piqley-cli

- [ ] **Step 1: Tag a new PiqleyCore release**

Check the latest tag in piqley-core and create the next patch/minor version. Since this is a breaking change (match is now optional), bump the minor version.

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && git tag --sort=-v:refname | head -5`

Create the tag (e.g., if latest is 0.14.0, tag 0.15.0):

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git push origin main
git tag <next-version>
git push origin <next-version>
```

- [ ] **Step 2: Update piqley-plugin-sdk to use new PiqleyCore version**

In piqley-plugin-sdk's `Package.swift`, update the piqley-core dependency minimum version to the new tag.

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift package update piqley-core`

Commit the Package.swift and Package.resolved changes.

- [ ] **Step 3: Update piqley-cli to use updated piqley-plugin-sdk**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift package update piqley-plugin-sdk`

Commit the Package.resolved changes.

- [ ] **Step 4: Verify piqley-cli builds and existing tests pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`
Expected: Build succeeds. Some tests that access `rule.match.field` (non-optional) will fail. These are fixed in Task 3.

## Task 3: Fix piqley-cli compilation with optional Rule.match

**Repo:** piqley-cli
**Files:**
- Modify: `Sources/piqley/State/RuleEvaluator.swift`
- Modify: `Sources/piqley/Plugins/RegexSanitizer.swift`
- Modify: `Sources/piqley/Wizard/RulesWizard+EditRuleMenu.swift`
- Modify: `Sources/piqley/Wizard/RulesWizard+UI.swift`
- Test: `Tests/piqleyTests/RuleEvaluatorTests.swift`
- Test: `Tests/piqleyTests/RuleTests.swift`
- Test: `Tests/piqleyTests/PluginInitTests.swift`
- Test: `Tests/piqleyTests/RegexSanitizerTests.swift`

- [ ] **Step 1: Update RuleEvaluator to handle optional match**

In `Sources/piqley/State/RuleEvaluator.swift`:

Add an `unconditional` flag to `CompiledRule`:

```swift
struct CompiledRule: Sendable {
    let unconditional: Bool
    let namespace: String
    let field: String
    let matcher: (any TagMatcher & Sendable)?
    let not: Bool
    let emitActions: [EmitAction]
    let writeActions: [EmitAction]
}
```

In the `init`, handle nil match:

```swift
for (index, rule) in rules.enumerated() {
    let namespace: String
    let field: String
    let matcher: (any TagMatcher & Sendable)?
    let not: Bool
    let unconditional: Bool

    if let match = rule.match {
        unconditional = false
        let split = Self.splitField(match.field, pluginId: pluginId)
        namespace = split.namespace
        field = split.field

        if namespace == "self" {
            let compError = RuleCompilationError.unresolvedSelf(ruleIndex: index)
            if nonInteractive {
                logger.warning("\(compError.localizedDescription) — skipping rule")
                continue
            }
            throw compError
        }

        do {
            matcher = try TagMatcherFactory.build(from: match.pattern)
        } catch {
            let compError = RuleCompilationError.invalidRegex(
                ruleIndex: index, pattern: match.pattern, underlying: error
            )
            if nonInteractive {
                logger.warning("\(compError.localizedDescription) — skipping rule")
                continue
            }
            throw compError
        }
        not = match.not ?? false
    } else {
        unconditional = true
        namespace = ""
        field = ""
        matcher = nil
        not = false
    }

    // Compile emit actions (unchanged)
    ...

    compiled.append(CompiledRule(
        unconditional: unconditional,
        namespace: namespace,
        field: field,
        matcher: matcher,
        not: not,
        emitActions: emitActions,
        writeActions: writeActions
    ))
}
```

In `evaluate`, handle unconditional rules:

```swift
for rule in compiledRules {
    let shouldApply: Bool

    if rule.unconditional {
        shouldApply = true
    } else {
        // Resolve the match field value (existing code)
        let value: JSONValue?
        if rule.namespace == "read", let buffer = metadataBuffer, let image = imageName {
            let fileMetadata = await buffer.load(image: image)
            value = fileMetadata[rule.field]
        } else if rule.namespace.isEmpty, rule.field == "skip", let image = imageName {
            value = Self.resolveSkipField(image: image, state: state)
        } else {
            value = state[rule.namespace]?[rule.field]
        }

        guard let value else { continue }

        let matched: Bool = switch value {
        case let .string(str):
            rule.matcher!.matches(str)
        case let .array(arr):
            arr.contains { element in
                if case let .string(str) = element {
                    return rule.matcher!.matches(str)
                }
                return false
            }
        default:
            false
        }

        shouldApply = rule.not ? !matched : matched
    }

    if shouldApply {
        // Apply emit and write actions (existing code, unchanged)
        ...
    }
}
```

- [ ] **Step 2: Update RegexSanitizer to handle optional match**

In `Sources/piqley/Plugins/RegexSanitizer.swift`, update `sanitizeRule`:

```swift
private static func sanitizeRule(_ rule: Rule) -> (Rule, Bool) {
    var didFix = false

    // Sanitize match pattern (only if match exists)
    let fixedMatch: MatchConfig?
    if let match = rule.match {
        let (fixedPattern, matchFix) = sanitize(match.pattern)
        if matchFix { didFix = true }
        fixedMatch = MatchConfig(field: match.field, pattern: fixedPattern, not: match.not)
    } else {
        fixedMatch = nil
    }

    // Sanitize emit configs (unchanged)
    let fixedEmit = rule.emit.map { emit -> EmitConfig in
        let (fixed, fix) = sanitizeEmitConfig(emit)
        if fix { didFix = true }
        return fixed
    }

    // Sanitize write configs (unchanged)
    let fixedWrite = rule.write.map { emit -> EmitConfig in
        let (fixed, fix) = sanitizeEmitConfig(emit)
        if fix { didFix = true }
        return fixed
    }

    return (Rule(match: fixedMatch, emit: fixedEmit, write: fixedWrite), didFix)
}
```

- [ ] **Step 3: Update EditRuleMenu to handle optional match**

In `Sources/piqley/Wizard/RulesWizard+EditRuleMenu.swift`:

Update `EditRuleState`:

```swift
struct EditRuleState {
    var matchField: String?
    var matchPattern: String?
    var matchNot: Bool?
    var emitActions: [EmitConfig]
    var writeActions: [EmitConfig]
}
```

Update `editRuleMenu` to init state from optional match:

```swift
func editRuleMenu(existing: Rule) -> Rule? {
    var state = EditRuleState(
        matchField: existing.match?.field,
        matchPattern: existing.match?.pattern,
        matchNot: existing.match?.not,
        emitActions: existing.emit,
        writeActions: existing.write
    )
    var cursor = 0

    while true {
        let items = buildEditRuleMenuItems(state: state)
        cursor = min(cursor, items.labels.count - 1)
        let title: String
        if let matchField = state.matchField, let matchPattern = state.matchPattern {
            let matchDesc = "\(resolveFieldDisplayName(matchField)) ~ \(matchPattern)"
            title = "Edit rule: \(matchDesc)"
        } else {
            title = "Edit rule: add (constant)"
        }
        ...
    }
}
```

Update `buildEditRuleMenuItems` to conditionally show match items:

```swift
func buildEditRuleMenuItems(state: EditRuleState) -> EditRuleMenuItems {
    var labels: [String] = []
    var tags: [EditRuleMenuTag] = []

    if let matchField = state.matchField {
        labels.append("Field: \(resolveFieldDisplayName(matchField))")
        tags.append(.matchField)

        labels.append("Pattern: \(state.matchPattern ?? "")")
        tags.append(.matchPattern)

        labels.append("Negated: \(state.matchNot == true ? "yes" : "no")")
        tags.append(.matchNegated)
    } else {
        labels.append("\(ANSI.dim)Type: add (constant)\(ANSI.reset)")
        tags.append(.save) // Non-editable, pressing enter on it is harmless (goes to save logic which validates)
    }

    // Rest unchanged: emit actions, write actions, save
    ...
}
```

Update `trySaveRule` to handle nil match:

```swift
private func trySaveRule(state: EditRuleState) -> Rule?? {
    var builder = RuleBuilder(context: context)

    if let matchField = state.matchField, let matchPattern = state.matchPattern {
        let matchResult = builder.setMatch(field: matchField, pattern: matchPattern)
        if case let .failure(error) = matchResult {
            showError(error)
            return nil
        }
    }

    for emit in state.emitActions {
        if case let .failure(error) = builder.addEmit(emit) {
            showError(error)
            return nil
        }
    }
    for write in state.writeActions {
        if case let .failure(error) = builder.addWrite(write) {
            showError(error)
            return nil
        }
    }

    switch builder.build() {
    case .success:
        let match: MatchConfig?
        if let matchField = state.matchField, let matchPattern = state.matchPattern {
            match = MatchConfig(field: matchField, pattern: matchPattern, not: state.matchNot)
        } else {
            match = nil
        }
        let rule = Rule(match: match, emit: state.emitActions, write: state.writeActions)
        return .some(rule)
    case let .failure(error):
        showError(error)
        return nil
    }
}
```

- [ ] **Step 4: Update RulesWizard+UI display methods**

In `Sources/piqley/Wizard/RulesWizard+UI.swift`:

Update `formatRule`:

```swift
func formatRule(_ rule: Rule, index: Int) -> String {
    let matchPrefix: String
    if let match = rule.match {
        matchPrefix = "\(match.field) ~ \(match.pattern)"
    } else {
        matchPrefix = "(always)"
    }
    let emitSummary = rule.emit.map { emit in
        let action = emit.action ?? "add"
        let target = emit.field ?? "keywords"
        if let values = emit.values {
            return "\(action) \(target)=[\(values.joined(separator: ", "))]"
        } else if let replacements = emit.replacements {
            let pairs = replacements.map { "\($0.pattern)\u{2192}\($0.replacement)" }
            return "replace \(target) [\(pairs.joined(separator: ", "))]"
        } else if let source = emit.source {
            return "clone \(target) from \(source)"
        }
        return "\(action) \(target)"
    }.joined(separator: "; ")
    let writeSummary = rule.write.isEmpty ? "" : " +write"
    return "\(index + 1). \(matchPrefix) \u{2192} \(emitSummary)\(writeSummary)"
}
```

Update `inspectRule` to handle nil match:

```swift
// In the match section of inspectRule:
if let match = rule.match {
    let displayName = resolveFieldDisplayName(match.field)
    buf += "\(ANSI.bold)Rule \(index + 1): \(displayName) ~ \(match.pattern)\(ANSI.reset)"
    // ... existing match section display
    buf += ANSI.moveTo(row: row, col: 1)
    let fieldDisplay: String = if displayName == match.field {
        displayName
    } else {
        "\(displayName)  \(ANSI.dim)(\(match.field))\(ANSI.reset)"
    }
    buf += "  Field:    \(fieldDisplay)"
    row += 1
    buf += ANSI.moveTo(row: row, col: 1)
    buf += "  Pattern:  \(match.pattern)"
    row += 1
    buf += ANSI.moveTo(row: row, col: 1)
    buf += "  Negated:  \(match.not == true ? "yes" : "no")"
    row += 2
} else {
    buf += "\(ANSI.bold)Rule \(index + 1): add (constant)\(ANSI.reset)"
    row = 3
    buf += ANSI.moveTo(row: row, col: 1)
    buf += "\(ANSI.dim)\u{2500}\u{2500} Match \(String(repeating: "\u{2500}", count: max(0, size.cols - 9)))\(ANSI.reset)"
    row += 1
    buf += ANSI.moveTo(row: row, col: 1)
    buf += "  \(ANSI.dim)(always applies)\(ANSI.reset)"
    row += 2
}
```

- [ ] **Step 5: Fix test files that access rule.match non-optionally**

In `Tests/piqleyTests/RuleEvaluatorTests.swift`, the `makeRule` helper already uses `MatchConfig` directly, so `Rule(match:emit:)` still works (non-nil match). No changes needed unless there are compilation errors from the optional type.

In `Tests/piqleyTests/RuleTests.swift`, update `rule.match.field` to `rule.match?.field` and `rule.match.pattern` to `rule.match?.pattern`.

In `Tests/piqleyTests/PluginInitTests.swift`, update `preRules[0].match.field` to `preRules[0].match?.field` and similar.

In `Tests/piqleyTests/RegexSanitizerTests.swift`, update `result.preRules![0].match.pattern` to `result.preRules![0].match?.pattern`.

- [ ] **Step 6: Run all piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```
fix: update piqley-cli for optional Rule.match

Adapts RuleEvaluator, RegexSanitizer, wizard UI, and tests
to handle unconditional rules with nil match.
```

## Task 4: Add unconditional rule evaluation test

**Repo:** piqley-cli
**Files:**
- Test: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing test for unconditional rule evaluation**

In `Tests/piqleyTests/RuleEvaluatorTests.swift`, add:

```swift
@Test("unconditional rule always fires")
func unconditionalRuleAlwaysFires() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(action: "add", field: "isFeatureImage", values: ["true"], replacements: nil, source: nil)]
    )
    let evaluator = try RuleEvaluator(
        rules: [rule],
        logger: logger
    )
    let result = await evaluator.evaluate(
        state: ["original": ["TIFF:Model": .string("Sony")]]
    )
    #expect(result.namespace["isFeatureImage"] == .array([.string("true")]))
}

@Test("unconditional rule fires with empty state")
func unconditionalRuleFiresWithEmptyState() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(action: "add", field: "isFeatureImage", values: ["true"], replacements: nil, source: nil)]
    )
    let evaluator = try RuleEvaluator(
        rules: [rule],
        logger: logger
    )
    let result = await evaluator.evaluate(state: [:])
    #expect(result.namespace["isFeatureImage"] == .array([.string("true")]))
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests/unconditionalRule 2>&1 | tail -20`
Expected: PASS (the evaluation changes from Task 3 should handle this)

- [ ] **Step 3: Commit**

```
test: add unconditional rule evaluation tests
```

## Task 5: Restructure wizard "add rule" flow

**Repo:** piqley-cli
**Files:**
- Modify: `Sources/piqley/Wizard/RulesWizard.swift`

- [ ] **Step 1: Replace buildRule and addActions with new action-type-first flow**

In `Sources/piqley/Wizard/RulesWizard.swift`, replace the `buildRule` method (for the non-editing case) and `addActions`/`addWriteActions`:

```swift
private func buildRule(editing existing: Rule? = nil) -> Rule? {
    if let existing {
        return editRuleMenu(existing: existing)
    }

    // Step 1: Select action type
    let actionLabels = [
        "add",
        "add (when matching)",
        "replace",
        "remove from",
        "remove field",
        "clone",
    ]
    guard let actionIdx = terminal.selectFromList(
        title: "Select rule type",
        items: actionLabels
    ) else { return nil }

    switch actionIdx {
    case 0:
        // Unconditional add
        return buildUnconditionalRule()
    case 1:
        // Conditional add (when matching)
        return buildConditionalRule(action: "add")
    case 2:
        return buildConditionalRule(action: "replace")
    case 3:
        return buildConditionalRule(action: "remove")
    case 4:
        return buildConditionalRule(action: "removeField")
    case 5:
        return buildConditionalRule(action: "clone")
    default:
        return nil
    }
}

private func buildUnconditionalRule() -> Rule? {
    var builder = RuleBuilder(context: context)

    guard let config = promptForEmitConfig(action: "add") else { return nil }
    let result = builder.addEmit(config)
    if case let .failure(error) = result {
        showError(error)
        return nil
    }

    // Write actions
    if terminal.confirm("Add write actions (modify file metadata)?") {
        let actions = ["add", "remove", "replace", "removeField", "clone"]
        while true {
            guard let writeIdx = terminal.selectFromList(
                title: "Select write action  \(ANSI.dim)(Esc when done)\(ANSI.reset)",
                items: actions
            ) else { break }
            guard let writeConfig = promptForEmitConfig(action: actions[writeIdx]) else { continue }
            let writeResult = builder.addWrite(writeConfig)
            if case let .failure(error) = writeResult {
                showError(error)
                continue
            }
            if !terminal.confirm("Add another write action?") { break }
        }
    }

    switch builder.build() {
    case let .success(rule):
        return rule
    case let .failure(error):
        showError(error)
        return nil
    }
}

private func buildConditionalRule(action: String) -> Rule? {
    var builder = RuleBuilder(context: context)

    // Step 1: Select source and field
    guard let selected = selectField() else { return nil }

    // Step 2: Enter pattern
    guard let pattern = terminal.promptForInput(
        title: "Enter match pattern for \(selected.displayName)",
        hint: "Plain text = exact match. Prefix with glob: or regex: for advanced.",
        defaultValue: nil
    ) else { return nil }

    let matchResult = builder.setMatch(
        field: selected.qualifiedName,
        pattern: pattern
    )
    if case let .failure(error) = matchResult {
        showError(error)
        return nil
    }

    // Step 3: Emit config for the selected action
    let matchDesc = "\(selected.qualifiedName) ~ \(pattern)"
    let whenLine = "\(ANSI.dim)When \(matchDesc)\(ANSI.reset)"

    guard let config = promptForEmitConfig(action: action) else { return nil }
    let result = builder.addEmit(config)
    if case let .failure(error) = result {
        showError(error)
        return nil
    }

    // Step 4: Write actions
    if terminal.confirm("Add write actions (modify file metadata)?") {
        let actions = ["add", "remove", "replace", "removeField", "clone"]
        while true {
            guard let writeIdx = terminal.selectFromList(
                title: "\(whenLine)\nSelect write action  \(ANSI.dim)(Esc when done)\(ANSI.reset)",
                items: actions
            ) else { break }
            guard let writeConfig = promptForEmitConfig(action: actions[writeIdx]) else { continue }
            let writeResult = builder.addWrite(writeConfig)
            if case let .failure(error) = writeResult {
                showError(error)
                continue
            }
            if !terminal.confirm("Add another write action?") { break }
        }
    }

    switch builder.build() {
    case let .success(rule):
        return rule
    case let .failure(error):
        showError(error)
        return nil
    }
}
```

Remove the old `addActions` and `addWriteActions` methods since they are no longer called.

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -20`
Expected: Compiles successfully.

- [ ] **Step 3: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```
feat: restructure wizard to support unconditional add rules

The "add rule" flow now presents action type first:
add, add (when matching), replace, remove from, remove field, clone.
"add" creates an unconditional rule with no match condition.
```
