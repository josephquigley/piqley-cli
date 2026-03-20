# Skip Rule Effect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `skip` emit action that halts pipeline processing for matched images and communicates skip status to downstream plugins.

**Architecture:** New `skip` action on EmitConfig flows through RuleValidator → RuleEvaluator → PipelineOrchestrator. Skip records are written to a reserved `skip` namespace per-image in StateStore, with a `skippedImages: Set<String>` for O(1) pipeline lookup. Plugin binaries receive a top-level `skipped` array on the wire payload.

**Tech Stack:** Swift, PiqleyCore (shared types), piqley-cli (evaluation/pipeline), PiqleyPluginSDK (builder DSL)

**Spec:** `docs/superpowers/specs/2026-03-20-skip-rule-effect-design.md`

**Test framework:** All tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `Issue.record`). Do NOT use XCTest.

**Conventions:**
- `RuleValidationTests` uses `makeEmit()` helper and `isSuccess()`/`isFailure()` Result matchers
- `RuleEvaluatorTests` uses `makeRule()` helper and `logger` property
- `PipelineOrchestratorTests` uses `makePluginsDir()`, `makeSourceDir()`, `makeTempScript()` free functions
- All tests use `#expect()` for assertions and `Issue.record()` instead of `XCTFail`

---

### Task 1: EmitConfig.field → String? and ReservedName.skip (PiqleyCore)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/Rule.swift:28-47`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Constants/ReservedName.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/RuleValidationTests.swift`

- [ ] **Step 1: Write failing test for EmitConfig with nil field**

In `RuleValidationTests.swift`, add inside the `@Suite` struct:

```swift
@Test func emitConfigAcceptsNilField() {
    let config = EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)
    #expect(config.field == nil)
    #expect(config.action == "skip")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleValidationTests/emitConfigAcceptsNilField 2>&1`
Expected: Compile error — `field` is `String`, not `String?`

- [ ] **Step 3: Change EmitConfig.field to String?**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/Rule.swift`, change line 32:

```swift
public struct EmitConfig: Codable, Sendable, Equatable {
    /// The action to perform: "add", "remove", "replace", "removeField", "clone", "skip". Nil defaults to "add".
    public let action: String?
    /// The target field. Required for all actions except skip. Use "*" with removeField/clone to target all fields.
    public let field: String?
    /// Values to add or patterns to remove. Required for add and remove actions.
    public let values: [String]?
    /// Ordered pattern-to-replacement mappings for the replace action.
    public let replacements: [Replacement]?
    /// Source namespace:field reference for clone action.
    public let source: String?

    public init(action: String?, field: String?, values: [String]?, replacements: [Replacement]?, source: String?) {
        self.action = action
        self.field = field
        self.values = values
        self.replacements = replacements
        self.source = source
    }
}
```

Existing callers pass `String` for `field`, which implicitly promotes to `String?` — no call site changes needed.

- [ ] **Step 4: Update makeEmit helper in tests**

The `makeEmit` helper's `field` parameter changes from `String` to `String?` with default `"Keywords"`. Also ensure it exposes a `source` parameter (needed by skip tests):

```swift
func makeEmit(
    action: String? = nil,
    field: String? = "Keywords",
    values: [String]? = ["foo"],
    replacements: [Replacement]? = nil,
    source: String? = nil
) -> EmitConfig {
    EmitConfig(action: action, field: field, values: values, replacements: replacements, source: source)
}
```

Note: The existing `makeEmit` may already have the `source` parameter. If not, add it.

- [ ] **Step 5: Add ReservedName.skip**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Constants/ReservedName.swift`:

```swift
public enum ReservedName {
    /// The namespace used for original image metadata before any plugin processing.
    public static let original = "original"
    /// The namespace used for skip records when images are excluded from pipeline processing.
    public static let skip = "skip"
    /// The field name within the skip namespace that holds skip records.
    public static let skipRecords = "records"
}
```

- [ ] **Step 6: Verify all packages build**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1`
Expected: Builds cleanly (implicit String → String? promotion)

- [ ] **Step 7: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add Sources/PiqleyCore/Config/Rule.swift Sources/PiqleyCore/Constants/ReservedName.swift Tests/PiqleyCoreTests/RuleValidationTests.swift
git commit -m "feat(core): make EmitConfig.field optional and add ReservedName.skip"
```

---

### Task 2: RuleValidationError new cases and RuleValidator skip support (PiqleyCore)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Validation/RuleValidationError.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Validation/RuleValidator.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/RuleValidationTests.swift`

- [ ] **Step 1: Write failing tests for skip validation**

Add inside the `@Suite` struct in `RuleValidationTests.swift`:

```swift
// MARK: - Skip Validation

@Test func validActionsContainsSkip() {
    #expect(RuleValidator.validActions.contains("skip"))
    #expect(RuleValidator.validActions.count == 6)
}

@Test func emitSkipValid() {
    let emit = makeEmit(action: "skip", field: nil, values: nil)
    let result = RuleValidator.validateEmit(emit)
    #expect(isSuccess(result))
}

@Test func emitSkipRejectsField() {
    let emit = makeEmit(action: "skip", field: "tags", values: nil)
    let result = RuleValidator.validateEmit(emit)
    #expect(isFailure(result, .conflictingFields(action: "skip")))
}

@Test func emitSkipRejectsValues() {
    let emit = makeEmit(action: "skip", field: nil, values: ["x"])
    let result = RuleValidator.validateEmit(emit)
    #expect(isFailure(result, .conflictingFields(action: "skip")))
}

@Test func emitSkipRejectsReplacements() {
    let emit = EmitConfig(action: "skip", field: nil, values: nil, replacements: [Replacement(pattern: "a", replacement: "b")], source: nil)
    let result = RuleValidator.validateEmit(emit)
    #expect(isFailure(result, .conflictingFields(action: "skip")))
}

@Test func emitSkipRejectsSource() {
    let emit = makeEmit(action: "skip", field: nil, values: nil, source: "original:IPTC:Keywords")
    let result = RuleValidator.validateEmit(emit)
    #expect(isFailure(result, .conflictingFields(action: "skip")))
}

@Test func validateRuleSkipWithWriteRejected() {
    let rule = Rule(
        match: MatchConfig(field: "original:IPTC:Keywords", pattern: "glob:*Draft*"),
        emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)],
        write: [EmitConfig(action: nil, field: "tags", values: ["x"], replacements: nil, source: nil)]
    )
    let result = RuleValidator.validateRule(rule)
    #expect(isFailure(result, .skipWithWrite))
}

@Test func validateRuleSkipNotAlone() {
    let rule = Rule(
        match: MatchConfig(field: "original:IPTC:Keywords", pattern: "glob:*Draft*"),
        emit: [
            EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil),
            EmitConfig(action: nil, field: "tags", values: ["x"], replacements: nil, source: nil)
        ]
    )
    let result = RuleValidator.validateRule(rule)
    #expect(isFailure(result, .skipNotAlone))
}

@Test func validateRuleNonSkipPassesValidation() {
    let rule = Rule(
        match: MatchConfig(field: "original:IPTC:Keywords", pattern: "glob:*"),
        emit: [EmitConfig(action: nil, field: "tags", values: ["x"], replacements: nil, source: nil)]
    )
    let result = RuleValidator.validateRule(rule)
    #expect(isSuccess(result))
}
```

Also update the existing `validActionsContainsAllFive` test — rename it and update count:

```swift
@Test func validActionsContainsAllSix() {
    let actions = RuleValidator.validActions
    #expect(actions.contains("add"))
    #expect(actions.contains("remove"))
    #expect(actions.contains("replace"))
    #expect(actions.contains("removeField"))
    #expect(actions.contains("clone"))
    #expect(actions.contains("skip"))
    #expect(actions.count == 6)
}
```

Update the `isFailure` helper to also work with `RuleValidationError` for rule-level validation:

The existing `isFailure` helper already works since `validateRule` returns `Result<Void, RuleValidationError>`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleValidationTests 2>&1`
Expected: Compile errors for `validateRule`, `skipWithWrite`, `skipNotAlone`; test failures for skip validation

- [ ] **Step 3: Add error cases to RuleValidationError**

In `RuleValidationError.swift`, add two new cases:

```swift
/// A skip rule must not have write actions.
case skipWithWrite

/// A skip emit must be the only action in the emit array.
case skipNotAlone
```

Add to `errorDescription`:
```swift
case .skipWithWrite:
    return "A rule with the 'skip' action must not have write actions."
case .skipNotAlone:
    return "The 'skip' action must be the only emit action in the rule."
```

Add to `recoverySuggestion`:
```swift
case .skipWithWrite:
    return "Remove the write section from the skip rule."
case .skipNotAlone:
    return "Remove other emit actions — skip must be the only action."
```

Add to `==`:
```swift
case (.skipWithWrite, .skipWithWrite):
    return true
case (.skipNotAlone, .skipNotAlone):
    return true
```

Update `.unknownAction` recovery suggestion to generate from `validActions`:
```swift
case .unknownAction:
    let valid = RuleValidator.validActions.sorted().joined(separator: ", ")
    return "Use one of the supported actions: \(valid)."
```

- [ ] **Step 4: Add "skip" to validActions and restructure validateEmit**

In `RuleValidator.swift`:

```swift
public static let validActions: Set<String> = ["add", "remove", "replace", "removeField", "clone", "skip"]
```

Replace `validateEmit`:

```swift
public static func validateEmit(_ emit: EmitConfig) -> Result<Void, RuleValidationError> {
    let action = emit.action ?? "add"

    guard validActions.contains(action) else {
        return .failure(.unknownAction(action))
    }

    switch action {
    case "skip":
        if emit.field != nil || emit.values != nil || emit.replacements != nil || emit.source != nil {
            return .failure(.conflictingFields(action: action))
        }

    case "add", "remove":
        guard let field = emit.field, !field.isEmpty else {
            return .failure(.emptyField)
        }
        if emit.replacements != nil || emit.source != nil {
            return .failure(.conflictingFields(action: action))
        }
        guard let values = emit.values, !values.isEmpty else {
            return .failure(.missingValues(action: action))
        }

    case "replace":
        guard let field = emit.field, !field.isEmpty else {
            return .failure(.emptyField)
        }
        if emit.values != nil || emit.source != nil {
            return .failure(.conflictingFields(action: action))
        }
        guard let replacements = emit.replacements, !replacements.isEmpty else {
            return .failure(.missingValues(action: action))
        }

    case "removeField":
        guard let field = emit.field, !field.isEmpty else {
            return .failure(.emptyField)
        }
        if emit.values != nil || emit.replacements != nil || emit.source != nil {
            return .failure(.conflictingFields(action: action))
        }

    case "clone":
        guard let field = emit.field, !field.isEmpty else {
            return .failure(.emptyField)
        }
        if emit.values != nil || emit.replacements != nil {
            return .failure(.conflictingFields(action: action))
        }
        guard let source = emit.source, !source.isEmpty else {
            return .failure(.missingSource)
        }

    default:
        break
    }

    return .success(())
}
```

Add `validateRule`:

```swift
/// Validates rule-level constraints that span match, emit, and write sections.
public static func validateRule(_ rule: Rule) -> Result<Void, RuleValidationError> {
    let hasSkip = rule.emit.contains { $0.action == "skip" }
    if hasSkip {
        if !rule.write.isEmpty {
            return .failure(.skipWithWrite)
        }
        if rule.emit.count > 1 {
            return .failure(.skipNotAlone)
        }
    }
    return .success(())
}
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add Sources/PiqleyCore/Validation/RuleValidator.swift Sources/PiqleyCore/Validation/RuleValidationError.swift Tests/PiqleyCoreTests/RuleValidationTests.swift
git commit -m "feat(core): add skip action to RuleValidator with rule-level validation"
```

---

### Task 3: SkipRecord in PiqleyCore (shared type)

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Payload/SkipRecord.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/RuleValidationTests.swift` (or a new test file)

`SkipRecord` lives in PiqleyCore because it's used in `PluginInputPayload` (PiqleyCore) and consumed by the SDK (which depends on PiqleyCore).

- [ ] **Step 1: Write failing test for SkipRecord serialization**

Add a test (in `RuleValidationTests.swift` or a new `SkipRecordTests.swift`):

```swift
@Suite("SkipRecord")
struct SkipRecordTests {
    @Test func encodesAndDecodes() throws {
        let record = SkipRecord(file: "IMG_001.jpg", plugin: "com.test.plugin")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SkipRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.file == "IMG_001.jpg")
        #expect(decoded.plugin == "com.test.plugin")
    }

    @Test func decodesFromJSON() throws {
        let json = #"{"file":"IMG_001.jpg","plugin":"com.test.plugin"}"#
        let record = try JSONDecoder().decode(SkipRecord.self, from: json.data(using: .utf8)!)
        #expect(record.file == "IMG_001.jpg")
        #expect(record.plugin == "com.test.plugin")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter SkipRecordTests 2>&1`
Expected: Compile error — `SkipRecord` doesn't exist

- [ ] **Step 3: Create SkipRecord**

Create `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Payload/SkipRecord.swift`:

```swift
/// A record indicating an image was skipped during pipeline processing.
public struct SkipRecord: Codable, Sendable, Equatable {
    /// The filename of the skipped image.
    public let file: String
    /// The identifier of the plugin that triggered the skip.
    public let plugin: String

    public init(file: String, plugin: String) {
        self.file = file
        self.plugin = plugin
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add Sources/PiqleyCore/Payload/SkipRecord.swift Tests/PiqleyCoreTests/SkipRecordTests.swift
git commit -m "feat(core): add SkipRecord type for skip wire payload"
```

---

### Task 4: PluginInputPayload.skipped field (PiqleyCore)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Payload/PluginInputPayload.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/SkipRecordTests.swift`

- [ ] **Step 1: Write failing test for backwards-compatible decoding**

Add to `SkipRecordTests.swift`:

```swift
@Test func payloadDecodesWithoutSkippedField() throws {
    // Simulate a legacy payload without the "skipped" key
    let json = """
    {
        "hook": "publish",
        "imageFolderPath": "/tmp/images",
        "pluginConfig": {},
        "secrets": {},
        "executionLogPath": "/tmp/log",
        "dataPath": "/tmp/data",
        "logPath": "/tmp/log.txt",
        "dryRun": false,
        "pluginVersion": "1.0.0"
    }
    """
    let payload = try JSONDecoder().decode(PluginInputPayload.self, from: json.data(using: .utf8)!)
    #expect(payload.skipped.isEmpty)
}

@Test func payloadDecodesWithSkippedField() throws {
    let json = """
    {
        "hook": "publish",
        "imageFolderPath": "/tmp/images",
        "pluginConfig": {},
        "secrets": {},
        "executionLogPath": "/tmp/log",
        "dataPath": "/tmp/data",
        "logPath": "/tmp/log.txt",
        "dryRun": false,
        "pluginVersion": "1.0.0",
        "skipped": [{"file": "IMG_001.jpg", "plugin": "com.test.plugin"}]
    }
    """
    let payload = try JSONDecoder().decode(PluginInputPayload.self, from: json.data(using: .utf8)!)
    #expect(payload.skipped.count == 1)
    #expect(payload.skipped[0].file == "IMG_001.jpg")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter SkipRecordTests 2>&1`
Expected: Compile error — `skipped` property doesn't exist on `PluginInputPayload`

- [ ] **Step 3: Add skipped field to PluginInputPayload**

In `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Payload/PluginInputPayload.swift`, add the property:

```swift
/// Images that were skipped during pipeline processing, with the plugin that skipped them.
public let skipped: [SkipRecord]
```

Two options for backwards compatibility:

**Option A (preferred):** Make `skipped` an optional `[SkipRecord]?` property with a default of `nil`. Add a convenience computed property `skippedRecords: [SkipRecord]` that returns `skipped ?? []`. This avoids needing a custom `init(from decoder:)` since Swift's synthesized Codable handles optional fields automatically.

**Option B:** Add a full custom `init(from decoder:)` that decodes all existing fields plus `skipped` via `decodeIfPresent`. Note: `PluginInputPayload` does NOT currently have a custom decoder, so this means writing one from scratch for all 11+ properties.

Choose Option A unless there is already a custom decoder. Update the `init` to include `skipped: [SkipRecord]? = nil`.

- [ ] **Step 4: Fix any callers in piqley-cli that construct PluginInputPayload**

The `PluginRunner.buildJSONPayload()` constructs `PluginInputPayload`. Add `skipped: []` to the init call for now (Task 7 will pass actual skip records).

- [ ] **Step 5: Run tests across packages**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1
```
Expected: All pass/build

- [ ] **Step 6: Commit**

```bash
git add Sources/PiqleyCore/Payload/PluginInputPayload.swift Tests/PiqleyCoreTests/SkipRecordTests.swift
git commit -m "feat(core): add skipped field to PluginInputPayload with backwards compat"
```

---

### Task 5: EmitAction.skip and compileEmitAction (CLI)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift:5-11,102-149,230-274`
- Test: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing test for skip compilation**

Add inside the `@Suite` struct in `RuleEvaluatorTests.swift`:

```swift
// MARK: - Skip Action

@Test("skip rule compiles successfully")
func skipRuleCompiles() throws {
    let rules = [makeRule(
        pattern: "glob:*Draft*",
        emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
    )]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    #expect(evaluator.compiledRules.count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests/skipRuleCompiles 2>&1`
Expected: Failure — `compileEmitAction` doesn't handle "skip"

- [ ] **Step 3: Add EmitAction.skip and update compilation**

In `RuleEvaluator.swift`, add `.skip` to `EmitAction`:

```swift
enum EmitAction: Sendable {
    case add(field: String, values: [String])
    case remove(field: String, matchers: [any TagMatcher & Sendable])
    case replace(field: String, replacements: [(matcher: any TagMatcher & Sendable, replacement: String)])
    case removeField(field: String)
    case clone(field: String, sourceNamespace: String, sourceField: String?)
    case skip
}
```

In `compileEmitAction`, add the skip case at the top of the switch, and guard-unwrap `config.field` for all existing actions (since it's now `String?`):

```swift
case "skip":
    return .skip

case "add":
    guard let field = config.field else {
        throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for add")
    }
    let values = config.values!
    return .add(field: field, values: values)

case "remove":
    guard let field = config.field else {
        throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for remove")
    }
    // ... rest unchanged, using `field` local ...

case "replace":
    guard let field = config.field else {
        throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for replace")
    }
    // ... rest unchanged, using `field` local ...

case "removeField":
    guard let field = config.field else {
        throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for removeField")
    }
    return .removeField(field: field)

case "clone":
    guard let field = config.field else {
        throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for clone")
    }
    // ... rest unchanged, using `field` local ...
```

Add `case .skip: break` to `applyAction(_:to:)` for exhaustive switch.

- [ ] **Step 4: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests 2>&1`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/State/RuleEvaluator.swift Tests/piqleyTests/RuleEvaluatorTests.swift
git commit -m "feat(cli): add EmitAction.skip and skip compilation in RuleEvaluator"
```

---

### Task 6: RuleEvaluationResult and skip evaluation (CLI)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift:156-228`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/StateStore.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing tests for skip evaluation**

Add to `RuleEvaluatorTests.swift`:

```swift
@Test("skip action halts further rule evaluation")
func skipActionHalts() async throws {
    let rules = [
        makeRule(
            field: "original:IPTC:Keywords",
            pattern: "glob:*Draft*",
            emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
        ),
        makeRule(
            field: "original:IPTC:Keywords",
            pattern: "glob:*",
            emit: [EmitConfig(action: nil, field: "tags", values: ["should-not-appear"], replacements: nil, source: nil)]
        )
    ]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    let state: [String: [String: JSONValue]] = [
        "original": ["IPTC:Keywords": .array([.string("Draft-Photo")])]
    ]
    let result = await evaluator.evaluate(
        state: state, imageName: "IMG_001.jpg", pluginId: "com.test.plugin"
    )
    #expect(result.skipped == true)
    #expect(result.namespace["tags"] == nil)
}

@Test("skip action writes skip record to state store")
func skipWritesRecord() async throws {
    let rules = [makeRule(
        field: "original:IPTC:Keywords",
        pattern: "glob:*Draft*",
        emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
    )]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    let stateStore = StateStore()
    let state: [String: [String: JSONValue]] = [
        "original": ["IPTC:Keywords": .array([.string("Draft-Photo")])]
    ]
    let result = await evaluator.evaluate(
        state: state, imageName: "IMG_001.jpg", pluginId: "com.test.plugin",
        stateStore: stateStore
    )
    #expect(result.skipped == true)
    let skipState = await stateStore.resolve(image: "IMG_001.jpg", dependencies: ["skip"])
    if case let .array(arr) = skipState["skip"]?["records"],
       case let .object(record) = arr.first {
        #expect(record["file"] == .string("IMG_001.jpg"))
        #expect(record["plugin"] == .string("com.test.plugin"))
    } else {
        Issue.record("Expected skip record, got \(String(describing: skipState["skip"]?["records"]))")
    }
}

@Test("no skip when rule doesn't match")
func noSkipOnMismatch() async throws {
    let rules = [makeRule(
        field: "original:IPTC:Keywords",
        pattern: "glob:*Draft*",
        emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
    )]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    let state: [String: [String: JSONValue]] = [
        "original": ["IPTC:Keywords": .array([.string("Portrait")])]
    ]
    let result = await evaluator.evaluate(
        state: state, imageName: "IMG_001.jpg", pluginId: "com.test.plugin"
    )
    #expect(result.skipped == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests/skipActionHalts 2>&1`
Expected: Compile errors — `evaluate` doesn't accept `pluginId`/`stateStore` or return `RuleEvaluationResult`

- [ ] **Step 3: Add RuleEvaluationResult and update evaluate()**

Add the result struct above `RuleEvaluator`:

```swift
struct RuleEvaluationResult: Sendable {
    let namespace: [String: JSONValue]
    let skipped: Bool
}
```

Update `evaluate` signature to accept optional `pluginId` and `stateStore`, and return `RuleEvaluationResult`:

```swift
func evaluate(
    state: [String: [String: JSONValue]],
    currentNamespace: [String: JSONValue] = [:],
    metadataBuffer: MetadataBuffer? = nil,
    imageName: String? = nil,
    pluginId: String? = nil,
    stateStore: StateStore? = nil
) async -> RuleEvaluationResult {
```

Inside the method, track `var skipped = false`. In the emit action loop, when `.skip` is encountered:

```swift
if case .skip = action {
    if let store = stateStore, let image = imageName, let plugin = pluginId {
        let record = JSONValue.object([
            "file": .string(image),
            "plugin": .string(plugin)
        ])
        await store.appendSkipRecord(image: image, record: record)
    }
    skipped = true
    break // stop processing emit actions
}
```

After the emit loop, if `skipped`, break out of the rules loop too:

```swift
if didSkip {
    skipped = true
    break // stop processing remaining rules
}
```

Return `RuleEvaluationResult(namespace: working, skipped: skipped)`.

- [ ] **Step 4: Add appendSkipRecord to StateStore**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/StateStore.swift`:

```swift
/// Appends a skip record for an image to the reserved skip namespace.
func appendSkipRecord(image: String, record: JSONValue) {
    if images[image] == nil {
        images[image] = [:]
    }
    if images[image]![ReservedName.skip] == nil {
        images[image]![ReservedName.skip] = [:]
    }
    var existing: [JSONValue] = []
    if case let .array(arr) = images[image]![ReservedName.skip]![ReservedName.skipRecords] {
        existing = arr
    }
    existing.append(record)
    images[image]![ReservedName.skip]![ReservedName.skipRecords] = .array(existing)
}
```

- [ ] **Step 5: Update all existing callers of evaluate()**

The existing tests call `evaluate()` and use the return value directly as `[String: JSONValue]`. Every call site must now use `.namespace` to get the dictionary. There are ~25 calls in `RuleEvaluatorTests.swift`. Do a find-and-replace:

Pattern: `await evaluator.evaluate(` returning to `result` or `let result = await evaluator.evaluate(`
Each needs `.namespace` appended where the result is used as a dictionary.

For example, change:
```swift
let result = await evaluator.evaluate(state: ...)
#expect(result["keywords"] == ...)
```
to:
```swift
let result = await evaluator.evaluate(state: ...)
#expect(result.namespace["keywords"] == ...)
```

Also update the one caller in `PipelineOrchestrator.evaluateRuleset`:
```swift
let ruleResult = await evaluator.evaluate(
    state: resolved, currentNamespace: currentNamespace,
    metadataBuffer: buffer, imageName: imageName
)
let ruleOutput = ruleResult.namespace
```

- [ ] **Step 6: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1`
Expected: All pass

- [ ] **Step 7: Commit**

```bash
git add Sources/piqley/State/RuleEvaluator.swift Sources/piqley/State/StateStore.swift Sources/piqley/Pipeline/PipelineOrchestrator.swift Tests/piqleyTests/RuleEvaluatorTests.swift
git commit -m "feat(cli): add RuleEvaluationResult and skip evaluation with state store write"
```

---

### Task 7: Skip match field resolution (CLI)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing tests for skip match field**

```swift
@Test("skip match field resolves from skip namespace")
func skipMatchFieldResolves() async throws {
    let rules = [makeRule(
        field: "skip",
        pattern: "glob:IMG_001*",
        emit: [EmitConfig(action: nil, field: "status", values: ["was-skipped"], replacements: nil, source: nil)]
    )]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    let skipRecord = JSONValue.object(["file": .string("IMG_001.jpg"), "plugin": .string("com.test.plugin")])
    let state: [String: [String: JSONValue]] = [
        "skip": ["records": .array([skipRecord])]
    ]
    let result = await evaluator.evaluate(state: state, imageName: "IMG_001.jpg")
    #expect(result.namespace["status"] == .array([.string("was-skipped")]))
}

@Test("skip match field does not match other images")
func skipMatchFieldNoMatchOtherImage() async throws {
    let rules = [makeRule(
        field: "skip",
        pattern: "glob:*",
        emit: [EmitConfig(action: nil, field: "status", values: ["was-skipped"], replacements: nil, source: nil)]
    )]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    let skipRecord = JSONValue.object(["file": .string("IMG_001.jpg"), "plugin": .string("com.test.plugin")])
    let state: [String: [String: JSONValue]] = [
        "skip": ["records": .array([skipRecord])]
    ]
    let result = await evaluator.evaluate(state: state, imageName: "IMG_002.jpg")
    #expect(result.namespace["status"] == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests/skipMatchFieldResolves 2>&1`
Expected: Fail — skip match resolution not implemented

- [ ] **Step 3: Add skip match field resolution**

In `evaluate()`, update the match field resolution block. When `rule.namespace` is empty and `rule.field` is `"skip"`, resolve specially:

```swift
let value: JSONValue?
if rule.namespace == "read", let buffer = metadataBuffer, let image = imageName {
    let fileMetadata = await buffer.load(image: image)
    value = fileMetadata[rule.field]
} else if rule.namespace.isEmpty, rule.field == "skip", let image = imageName {
    // Special skip match: check if the current image is in the skip records
    if case let .array(records) = state[ReservedName.skip]?[ReservedName.skipRecords] {
        let isSkipped = records.contains { record in
            if case let .object(dict) = record, case let .string(file) = dict["file"] {
                return file == image
            }
            return false
        }
        value = isSkipped ? .string(image) : nil
    } else {
        value = nil
    }
} else {
    value = state[rule.namespace]?[rule.field]
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests 2>&1`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/State/RuleEvaluator.swift Tests/piqleyTests/RuleEvaluatorTests.swift
git commit -m "feat(cli): add special skip match field resolution in RuleEvaluator"
```

---

### Task 8: Pipeline integration — evaluateRuleset and runPluginHook (CLI)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`
- Test: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PipelineOrchestratorTests.swift`

- [ ] **Step 1: Write failing test for pipeline skip behavior**

Add a helper to create a plugins directory with pre-rules, using the existing test patterns:

```swift
private func makePluginsDirWithSkipRule(identifier: String, hook: String, scriptURL: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
    let pluginDir = dir.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
        "identifier": identifier,
        "name": identifier,
        "pluginSchemaVersion": "1"
    ]
    try JSONSerialization.data(withJSONObject: manifest)
        .write(to: pluginDir.appendingPathComponent("manifest.json"))

    // Stage config with pre-rule that skips Draft images + binary
    let skipEmit: [String: Any] = ["action": "skip"]
    let matchConfig: [String: Any] = ["field": "original:IPTC:Keywords", "pattern": "glob:*Draft*"]
    let stageConfig: [String: Any] = [
        "preRules": [["match": matchConfig, "emit": [skipEmit]]],
        "binary": ["command": scriptURL.path, "args": [], "protocol": "pipe"]
    ]
    try JSONSerialization.data(withJSONObject: stageConfig)
        .write(to: pluginDir.appendingPathComponent("stage-\(hook).json"))

    try FileManager.default.createDirectory(
        at: pluginDir.appendingPathComponent("data"), withIntermediateDirectories: true
    )
    return dir
}
```

Then the test:

```swift
@Test("skip rule prevents binary execution for matched image")
func skipRulePreventsBinary() async throws {
    let markerPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-skip-marker-\(UUID().uuidString)")
    let script = try makeTempScript("touch \"\(markerPath.path)\"")
    defer { try? FileManager.default.removeItem(at: script) }

    let pluginsDir = try makePluginsDirWithSkipRule(
        identifier: "com.test.skip-plugin", hook: "pre-process", scriptURL: script
    )
    defer { try? FileManager.default.removeItem(at: pluginsDir) }

    // Create source with a Draft-tagged image
    let sourceDir = try makeSourceDir(withImage: false)
    defer { try? FileManager.default.removeItem(at: sourceDir) }
    try TestFixtures.createTestJPEG(
        at: sourceDir.appendingPathComponent("photo.jpg").path,
        keywords: ["Draft-Photo"]
    )

    var config = AppConfig()
    config.pipeline["pre-process"] = ["com.test.skip-plugin"]
    config.autoDiscoverPlugins = false

    let orchestrator = PipelineOrchestrator(
        config: config, pluginsDirectory: pluginsDir, secretStore: FakeSecretStore()
    )
    let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
    #expect(result == true)
    #expect(!FileManager.default.fileExists(atPath: markerPath.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter PipelineOrchestratorTests/skipRulePreventsBinary 2>&1`
Expected: Fail — binary still runs because skip is not wired into pipeline

- [ ] **Step 3: Add RulesetResult and update evaluateRuleset**

Add `RulesetResult` struct and update `evaluateRuleset` to accept `skippedImages`, skip already-skipped images, pass `pluginId` and `stateStore` to `evaluate()`, and return `RulesetResult`:

```swift
private struct RulesetResult {
    let didRun: Bool
    let skippedImages: Set<String>
}

private func evaluateRuleset(
    rules: [Rule],
    ctx: HookContext,
    manifestDeps: [String],
    buffer: MetadataBuffer,
    ruleEvaluatorCache: inout [String: RuleEvaluator],
    cacheKey: String,
    skippedImages: Set<String> = []
) async throws -> RulesetResult {
    let evaluator: RuleEvaluator
    if let cached = ruleEvaluatorCache[cacheKey] {
        evaluator = cached
    } else {
        evaluator = try RuleEvaluator(rules: rules, nonInteractive: ctx.nonInteractive, logger: logger)
        ruleEvaluatorCache[cacheKey] = evaluator
    }

    var didRun = false
    var newSkipped = skippedImages
    for imageName in await ctx.stateStore.allImageNames {
        if skippedImages.contains(imageName) { continue }

        let resolved = await ctx.stateStore.resolve(
            image: imageName,
            dependencies: manifestDeps + [ReservedName.original, ReservedName.skip, ctx.pluginIdentifier]
        )
        let currentNamespace = resolved[ctx.pluginIdentifier] ?? [:]
        let ruleResult = await evaluator.evaluate(
            state: resolved, currentNamespace: currentNamespace,
            metadataBuffer: buffer, imageName: imageName,
            pluginId: ctx.pluginIdentifier, stateStore: ctx.stateStore
        )
        if ruleResult.skipped {
            newSkipped.insert(imageName)
        }
        let ruleOutput = ruleResult.namespace
        if ruleOutput != currentNamespace {
            await ctx.stateStore.setNamespace(
                image: imageName, plugin: ctx.pluginIdentifier, values: ruleOutput
            )
            didRun = true
        }
    }
    return RulesetResult(didRun: didRun, skippedImages: newSkipped)
}
```

- [ ] **Step 4: Update runPluginHook to track skipped images**

In `runPluginHook`, change the pre-rules block to use `RulesetResult`, filter binary execution by checking if all images are skipped, and pass `skippedImages` through post-rules:

```swift
// Pre-rules
var skippedImages: Set<String> = ctx.skippedImages
var preRulesDidRun = false
if let preRules = stageConfig.preRules, !preRules.isEmpty {
    do {
        let result = try await evaluateRuleset(
            rules: preRules, ctx: ctx, manifestDeps: manifestDeps,
            buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
            cacheKey: "\(ctx.pluginIdentifier):pre:\(ctx.hook)",
            skippedImages: skippedImages
        )
        preRulesDidRun = result.didRun
        skippedImages = result.skippedImages
    } catch { ... }
}

// Binary — skip if all images are skipped
let nonSkippedCount = ctx.imageFiles.filter { !skippedImages.contains($0.lastPathComponent) }.count
var binaryDidRun = false
if stageConfig.binary?.command != nil, nonSkippedCount > 0 {
    // ... existing runBinary call ...
}
```

- [ ] **Step 5: Add skippedImages to HookContext and main loop**

Add `skippedImages: Set<String>` to `HookContext`. In the `run()` method, maintain a running set:

```swift
var skippedImages: Set<String> = []
// In the hook loop:
var ctx = HookContext(..., skippedImages: skippedImages)
```

Update `runPluginHook` to return `(HookResult, Set<String>)` so the main loop can collect skipped images across plugins.

- [ ] **Step 6: Pass skipped records to PluginRunner**

Update `runBinary` to accept `skippedImages: Set<String>`. Build `[SkipRecord]` from the state store for skipped images and pass to `PluginInputPayload`:

```swift
var skipRecords: [SkipRecord] = []
for skippedImage in skippedImages {
    let skipState = await ctx.stateStore.resolve(image: skippedImage, dependencies: [ReservedName.skip])
    if case let .array(records) = skipState[ReservedName.skip]?[ReservedName.skipRecords] {
        for record in records {
            if case let .object(dict) = record,
               case let .string(file) = dict["file"],
               case let .string(plugin) = dict["plugin"] {
                skipRecords.append(SkipRecord(file: file, plugin: plugin))
            }
        }
    }
}
```

Pass `skipRecords` through to `PluginRunner` which includes them in `PluginInputPayload(... skipped: skipRecords)`.

- [ ] **Step 7: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift Sources/piqley/Plugins/PluginRunner.swift Tests/piqleyTests/PipelineOrchestratorTests.swift
git commit -m "feat(cli): integrate skip into pipeline orchestrator with image filtering"
```

---

### Task 9: SDK RuleEmit.skip and builder DSL (PiqleyPluginSDK)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`

- [ ] **Step 1: Write failing test for RuleEmit.skip**

Check if SDK has tests for `toEmitConfig()`. If so, add:

```swift
@Test func skipEmitConfig() {
    let config = RuleEmit.skip.toEmitConfig()
    #expect(config.action == "skip")
    #expect(config.field == nil)
    #expect(config.values == nil)
    #expect(config.replacements == nil)
    #expect(config.source == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter skipEmitConfig 2>&1`
Expected: Compile error — `.skip` case doesn't exist

- [ ] **Step 3: Add .skip case to RuleEmit**

In `ConfigBuilder.swift`, add to `RuleEmit`:

```swift
case skip
```

Add to `toEmitConfig()`:

```swift
case .skip:
    return EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)
```

- [ ] **Step 4: Build and test SDK**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift
git commit -m "feat(sdk): add RuleEmit.skip case for builder DSL"
```

---

### Task 10: Final integration verification

- [ ] **Step 1: Run full test suite across all packages**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1
```
Expected: All pass with zero failures

- [ ] **Step 2: Verify no regressions**

Confirm existing tests still pass — especially the ~25 `RuleEvaluatorTests` that were updated to use `.namespace` and the `RuleValidationTests` that use the updated `makeEmit` helper.

- [ ] **Step 3: Final commit if needed**

```bash
git add -A && git commit -m "test: verify skip rule effect integration across all packages"
```
