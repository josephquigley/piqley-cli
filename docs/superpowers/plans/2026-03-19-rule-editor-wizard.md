# Rule Editor Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an interactive TUI wizard for editing declarative metadata rules on installed plugins, driven by a shared Core validation layer.

**Architecture:** PiqleyCore gains `RuleEditingContext`, `RuleBuilder`, `RuleValidationError`, `FieldInfo`, `MetadataFieldCatalog`, and `StageConfig` mutations. The CLI adds a `piqley plugin rules edit <plugin-id>` command that launches a TermKit-based full-screen wizard. Core validates; CLI discovers fields and owns UX.

**Tech Stack:** Swift 6.0 (Core) / 6.2 (CLI), Apple Testing framework, PiqleyCore, TermKit, ArgumentParser

**Spec:** `docs/superpowers/specs/2026-03-19-rule-editor-wizard-design.md`

---

## File Structure

### PiqleyCore (new files)

| File | Responsibility |
|------|---------------|
| `Sources/PiqleyCore/Config/RuleSlot.swift` | `RuleSlot` enum (pre/post) |
| `Sources/PiqleyCore/Config/StageConfig+Mutation.swift` | `appendRule`, `removeRule`, `moveRule`, `replaceRule` |
| `Sources/PiqleyCore/Validation/RuleValidationError.swift` | Localized error enum with recovery suggestions |
| `Sources/PiqleyCore/Validation/RuleValidator.swift` | Static validation methods (shared by builder + evaluator) |
| `Sources/PiqleyCore/RuleEditing/FieldInfo.swift` | `FieldInfo` struct + `FieldCategory` enum |
| `Sources/PiqleyCore/RuleEditing/MetadataFieldCatalog.swift` | Hardcoded EXIF/IPTC/XMP/TIFF field lists |
| `Sources/PiqleyCore/RuleEditing/RuleEditingContext.swift` | Context type with query methods |
| `Sources/PiqleyCore/RuleEditing/RuleBuilder.swift` | Fluent builder with inline validation |

### PiqleyCore (modified files)

| File | Change |
|------|--------|
| `Sources/PiqleyCore/Config/StageConfig.swift` | Change `let` to `var` for `preRules`, `postRules` |

### PiqleyCore (new test files)

| File | Tests |
|------|-------|
| `Tests/PiqleyCoreTests/StageConfigMutationTests.swift` | append/remove/move/replace, nil handling |
| `Tests/PiqleyCoreTests/RuleValidationTests.swift` | All validation cases, error messages |
| `Tests/PiqleyCoreTests/RuleBuilderTests.swift` | Builder flow, validation gating, build |
| `Tests/PiqleyCoreTests/MetadataFieldCatalogTests.swift` | Catalog completeness, sorting |
| `Tests/PiqleyCoreTests/RuleEditingContextTests.swift` | Query methods, field filtering |

### CLI (new files)

| File | Responsibility |
|------|---------------|
| `Sources/piqley/CLI/PluginRulesCommand.swift` | Command group + edit subcommand |
| `Sources/piqley/Wizard/RulesWizardApp.swift` | TermKit Application entry point |
| `Sources/piqley/Wizard/StageSelectScreen.swift` | Stage picker screen |
| `Sources/piqley/Wizard/RuleListScreen.swift` | Rule list with filter + actions |
| `Sources/piqley/Wizard/RuleEditorScreen.swift` | Multi-step rule creation/editing |
| `Sources/piqley/Wizard/FieldDiscovery.swift` | Builds `availableFields` from installed plugins |

### CLI (modified files)

| File | Change |
|------|--------|
| `Sources/piqley/CLI/PluginCommand.swift` | Add `PluginRulesCommand.self` to subcommands |
| `Sources/piqley/State/RuleEvaluator.swift` | Delegate validation to `RuleValidator` |
| `Package.swift` | Add TermKit dependency |

### CLI (new test files)

| File | Tests |
|------|-------|
| `Tests/piqleyTests/FieldDiscoveryTests.swift` | Field building from manifests + catalog |

---

## Task 1: RuleSlot + StageConfig Mutations (PiqleyCore)

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/Config/RuleSlot.swift`
- Create: `piqley-core/Sources/PiqleyCore/Config/StageConfig+Mutation.swift`
- Modify: `piqley-core/Sources/PiqleyCore/Config/StageConfig.swift:3-4` (let → var)
- Test: `piqley-core/Tests/PiqleyCoreTests/StageConfigMutationTests.swift`

- [ ] **Step 1: Write failing tests for StageConfig mutations**

```swift
// Tests/PiqleyCoreTests/StageConfigMutationTests.swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("StageConfig Mutations")
struct StageConfigMutationTests {

    private let sampleRule = Rule(
        match: MatchConfig(field: "original:TIFF:Model", pattern: "Sony"),
        emit: [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]
    )

    private let anotherRule = Rule(
        match: MatchConfig(field: "original:EXIF:ISO", pattern: "regex:\\d{5}"),
        emit: [EmitConfig(action: nil, field: "keywords", values: ["high-iso"], replacements: nil, source: nil)]
    )

    // MARK: - appendRule

    @Test("append rule to nil preRules initializes array")
    func appendToNilPre() {
        var stage = StageConfig(preRules: nil, binary: nil, postRules: nil)
        stage.appendRule(sampleRule, slot: .pre)
        #expect(stage.preRules?.count == 1)
        #expect(stage.preRules?[0] == sampleRule)
    }

    @Test("append rule to existing preRules adds to end")
    func appendToExistingPre() {
        var stage = StageConfig(preRules: [sampleRule], binary: nil, postRules: nil)
        stage.appendRule(anotherRule, slot: .pre)
        #expect(stage.preRules?.count == 2)
        #expect(stage.preRules?[1] == anotherRule)
    }

    @Test("append rule to postRules slot")
    func appendToPost() {
        var stage = StageConfig(preRules: nil, binary: nil, postRules: nil)
        stage.appendRule(sampleRule, slot: .post)
        #expect(stage.postRules?.count == 1)
        #expect(stage.postRules?[0] == sampleRule)
    }

    // MARK: - removeRule

    @Test("remove rule at valid index")
    func removeAtValidIndex() throws {
        var stage = StageConfig(preRules: [sampleRule, anotherRule], binary: nil, postRules: nil)
        try stage.removeRule(at: 0, slot: .pre)
        #expect(stage.preRules?.count == 1)
        #expect(stage.preRules?[0] == anotherRule)
    }

    @Test("remove last rule sets slot to nil")
    func removeLastRule() throws {
        var stage = StageConfig(preRules: [sampleRule], binary: nil, postRules: nil)
        try stage.removeRule(at: 0, slot: .pre)
        #expect(stage.preRules == nil)
    }

    @Test("remove rule at invalid index throws")
    func removeAtInvalidIndex() {
        var stage = StageConfig(preRules: [sampleRule], binary: nil, postRules: nil)
        #expect(throws: RuleSlotError.self) {
            try stage.removeRule(at: 5, slot: .pre)
        }
    }

    @Test("remove from nil slot throws")
    func removeFromNilSlot() {
        var stage = StageConfig(preRules: nil, binary: nil, postRules: nil)
        #expect(throws: RuleSlotError.self) {
            try stage.removeRule(at: 0, slot: .pre)
        }
    }

    // MARK: - moveRule

    @Test("move rule reorders correctly")
    func moveRule() throws {
        let thirdRule = Rule(
            match: MatchConfig(field: "original:TIFF:Make", pattern: "Nikon"),
            emit: [EmitConfig(action: nil, field: "keywords", values: ["nikon"], replacements: nil, source: nil)]
        )
        var stage = StageConfig(preRules: [sampleRule, anotherRule, thirdRule], binary: nil, postRules: nil)
        try stage.moveRule(from: 2, to: 0, slot: .pre)
        #expect(stage.preRules?[0] == thirdRule)
        #expect(stage.preRules?[1] == sampleRule)
        #expect(stage.preRules?[2] == anotherRule)
    }

    @Test("move rule with invalid index throws")
    func moveInvalidIndex() {
        var stage = StageConfig(preRules: [sampleRule], binary: nil, postRules: nil)
        #expect(throws: RuleSlotError.self) {
            try stage.moveRule(from: 0, to: 5, slot: .pre)
        }
    }

    // MARK: - replaceRule

    @Test("replace rule at valid index")
    func replaceAtValidIndex() throws {
        var stage = StageConfig(preRules: [sampleRule], binary: nil, postRules: nil)
        try stage.replaceRule(at: 0, with: anotherRule, slot: .pre)
        #expect(stage.preRules?[0] == anotherRule)
    }

    @Test("replace rule at invalid index throws")
    func replaceAtInvalidIndex() {
        var stage = StageConfig(preRules: [sampleRule], binary: nil, postRules: nil)
        #expect(throws: RuleSlotError.self) {
            try stage.replaceRule(at: 5, with: anotherRule, slot: .pre)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter StageConfigMutation 2>&1 | tail -5`
Expected: Compilation errors — `RuleSlot`, mutation methods, `RuleSlotError` don't exist yet.

- [ ] **Step 3: Create RuleSlot enum**

```swift
// Sources/PiqleyCore/Config/RuleSlot.swift

/// Identifies which rule array within a StageConfig to target.
public enum RuleSlot: String, Sendable, CaseIterable {
    case pre
    case post
}

/// Error thrown when a stage mutation targets an invalid index.
public enum RuleSlotError: Error, LocalizedError, Sendable {
    case indexOutOfBounds(index: Int, count: Int, slot: RuleSlot)
    case emptySlot(slot: RuleSlot)

    public var errorDescription: String? {
        switch self {
        case let .indexOutOfBounds(index, count, slot):
            "Index \(index) is out of bounds for \(slot.rawValue)-rules (count: \(count))."
        case let .emptySlot(slot):
            "The \(slot.rawValue)-rules slot is empty."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .indexOutOfBounds:
            "Use an index within the valid range."
        case .emptySlot:
            "Add a rule before attempting to modify the slot."
        }
    }
}
```

- [ ] **Step 4: Change StageConfig properties from let to var**

In `piqley-core/Sources/PiqleyCore/Config/StageConfig.swift`, change:
```swift
public let preRules: [Rule]?
```
to:
```swift
public var preRules: [Rule]?
```
And:
```swift
public let postRules: [Rule]?
```
to:
```swift
public var postRules: [Rule]?
```

- [ ] **Step 5: Implement StageConfig mutation methods**

```swift
// Sources/PiqleyCore/Config/StageConfig+Mutation.swift

extension StageConfig {
    /// Append a rule to the end of the specified slot.
    /// If the slot is nil, initializes it with the rule.
    public mutating func appendRule(_ rule: Rule, slot: RuleSlot) {
        switch slot {
        case .pre:
            if preRules != nil {
                preRules!.append(rule)
            } else {
                preRules = [rule]
            }
        case .post:
            if postRules != nil {
                postRules!.append(rule)
            } else {
                postRules = [rule]
            }
        }
    }

    /// Remove the rule at the given index. Sets slot to nil if last rule removed.
    public mutating func removeRule(at index: Int, slot: RuleSlot) throws {
        switch slot {
        case .pre:
            guard var rules = preRules else {
                throw RuleSlotError.emptySlot(slot: slot)
            }
            guard rules.indices.contains(index) else {
                throw RuleSlotError.indexOutOfBounds(index: index, count: rules.count, slot: slot)
            }
            rules.remove(at: index)
            preRules = rules.isEmpty ? nil : rules
        case .post:
            guard var rules = postRules else {
                throw RuleSlotError.emptySlot(slot: slot)
            }
            guard rules.indices.contains(index) else {
                throw RuleSlotError.indexOutOfBounds(index: index, count: rules.count, slot: slot)
            }
            rules.remove(at: index)
            postRules = rules.isEmpty ? nil : rules
        }
    }

    /// Move a rule from one position to another within the same slot.
    public mutating func moveRule(from source: Int, to destination: Int, slot: RuleSlot) throws {
        switch slot {
        case .pre:
            guard var rules = preRules else {
                throw RuleSlotError.emptySlot(slot: slot)
            }
            guard rules.indices.contains(source) else {
                throw RuleSlotError.indexOutOfBounds(index: source, count: rules.count, slot: slot)
            }
            guard destination >= 0 && destination <= rules.count - 1 else {
                throw RuleSlotError.indexOutOfBounds(index: destination, count: rules.count, slot: slot)
            }
            let rule = rules.remove(at: source)
            rules.insert(rule, at: destination)
            preRules = rules
        case .post:
            guard var rules = postRules else {
                throw RuleSlotError.emptySlot(slot: slot)
            }
            guard rules.indices.contains(source) else {
                throw RuleSlotError.indexOutOfBounds(index: source, count: rules.count, slot: slot)
            }
            guard destination >= 0 && destination <= rules.count - 1 else {
                throw RuleSlotError.indexOutOfBounds(index: destination, count: rules.count, slot: slot)
            }
            let rule = rules.remove(at: source)
            rules.insert(rule, at: destination)
            postRules = rules
        }
    }

    /// Replace the rule at the given index.
    public mutating func replaceRule(at index: Int, with rule: Rule, slot: RuleSlot) throws {
        switch slot {
        case .pre:
            guard var rules = preRules else {
                throw RuleSlotError.emptySlot(slot: slot)
            }
            guard rules.indices.contains(index) else {
                throw RuleSlotError.indexOutOfBounds(index: index, count: rules.count, slot: slot)
            }
            rules[index] = rule
            preRules = rules
        case .post:
            guard var rules = postRules else {
                throw RuleSlotError.emptySlot(slot: slot)
            }
            guard rules.indices.contains(index) else {
                throw RuleSlotError.indexOutOfBounds(index: index, count: rules.count, slot: slot)
            }
            rules[index] = rule
            postRules = rules
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter StageConfigMutation 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 7: Run full Core test suite to check for regressions**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -5`
Expected: All tests PASS. The `let` → `var` change should not break existing code since `var` is a superset.

- [ ] **Step 8: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Config/RuleSlot.swift Sources/PiqleyCore/Config/StageConfig+Mutation.swift Sources/PiqleyCore/Config/StageConfig.swift Tests/PiqleyCoreTests/StageConfigMutationTests.swift
git commit -m "feat: add RuleSlot and StageConfig mutation methods"
```

---

## Task 2: RuleValidationError + RuleValidator (PiqleyCore)

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/Validation/RuleValidationError.swift`
- Create: `piqley-core/Sources/PiqleyCore/Validation/RuleValidator.swift`
- Test: `piqley-core/Tests/PiqleyCoreTests/RuleValidationTests.swift`

- [ ] **Step 1: Write failing tests for validation**

```swift
// Tests/PiqleyCoreTests/RuleValidationTests.swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("RuleValidator")
struct RuleValidationTests {

    // MARK: - Match validation

    @Test("valid exact match passes")
    func validExactMatch() {
        let result = RuleValidator.validateMatch(field: "original:TIFF:Model", pattern: "Sony")
        #expect(result == .success(()))
    }

    @Test("valid glob match passes")
    func validGlobMatch() {
        let result = RuleValidator.validateMatch(field: "original:TIFF:Model", pattern: "glob:Canon*")
        #expect(result == .success(()))
    }

    @Test("valid regex match passes")
    func validRegexMatch() {
        let result = RuleValidator.validateMatch(field: "original:TIFF:Model", pattern: "regex:.*a7r.*")
        #expect(result == .success(()))
    }

    @Test("empty field fails")
    func emptyField() {
        let result = RuleValidator.validateMatch(field: "", pattern: "Sony")
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(error == .emptyField)
        #expect(error.errorDescription != nil)
        #expect(error.recoverySuggestion != nil)
    }

    @Test("invalid regex fails")
    func invalidRegex() {
        let result = RuleValidator.validateMatch(field: "original:TIFF:Model", pattern: "regex:[invalid")
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        if case .invalidPattern = error {} else {
            Issue.record("Expected invalidPattern, got \(error)")
        }
    }

    // MARK: - Emit validation

    @Test("valid add action passes")
    func validAdd() {
        let config = EmitConfig(action: "add", field: "keywords", values: ["sony"], replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        #expect(result == .success(()))
    }

    @Test("valid nil action defaults to add and passes")
    func nilActionDefaultsAdd() {
        let config = EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        #expect(result == .success(()))
    }

    @Test("add action without values fails")
    func addWithoutValues() {
        let config = EmitConfig(action: "add", field: "keywords", values: nil, replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        guard case .failure(.missingValues) = result else {
            Issue.record("Expected missingValues failure")
            return
        }
    }

    @Test("add action with empty values fails")
    func addWithEmptyValues() {
        let config = EmitConfig(action: "add", field: "keywords", values: [], replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        guard case .failure(.missingValues) = result else {
            Issue.record("Expected missingValues failure")
            return
        }
    }

    @Test("replace action with values fails")
    func replaceWithValues() {
        let config = EmitConfig(action: "replace", field: "keywords", values: ["bad"], replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        guard case .failure(.conflictingFields) = result else {
            Issue.record("Expected conflictingFields failure")
            return
        }
    }

    @Test("valid replace action passes")
    func validReplace() {
        let config = EmitConfig(
            action: "replace", field: "keywords",
            values: nil,
            replacements: [Replacement(pattern: "old", replacement: "new")],
            source: nil
        )
        let result = RuleValidator.validateEmit(config)
        #expect(result == .success(()))
    }

    @Test("valid removeField action passes")
    func validRemoveField() {
        let config = EmitConfig(action: "removeField", field: "keywords", values: nil, replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        #expect(result == .success(()))
    }

    @Test("valid clone action passes")
    func validClone() {
        let config = EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")
        let result = RuleValidator.validateEmit(config)
        #expect(result == .success(()))
    }

    @Test("clone without source fails")
    func cloneWithoutSource() {
        let config = EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        guard case .failure(.missingSource) = result else {
            Issue.record("Expected missingSource failure")
            return
        }
    }

    @Test("unknown action fails")
    func unknownAction() {
        let config = EmitConfig(action: "yeet", field: "keywords", values: ["a"], replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        guard case .failure(.unknownAction) = result else {
            Issue.record("Expected unknownAction failure")
            return
        }
    }

    @Test("empty emit field fails")
    func emptyEmitField() {
        let config = EmitConfig(action: "add", field: "", values: ["a"], replacements: nil, source: nil)
        let result = RuleValidator.validateEmit(config)
        guard case .failure(.emptyField) = result else {
            Issue.record("Expected emptyField failure")
            return
        }
    }

    // MARK: - Error messages

    @Test("all errors have descriptions and recovery suggestions")
    func allErrorsHaveMessages() {
        let errors: [RuleValidationError] = [
            .emptyField,
            .invalidPattern("bad", underlying: NSError(domain: "test", code: 0)),
            .unknownAction("yeet"),
            .missingValues(action: "add"),
            .missingSource,
            .conflictingFields(action: "replace"),
            .noMatch,
            .noActions,
        ]
        for error in errors {
            #expect(error.errorDescription != nil, "Missing description for \(error)")
            #expect(error.recoverySuggestion != nil, "Missing recovery for \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleValidation 2>&1 | tail -5`
Expected: Compilation errors — types don't exist.

- [ ] **Step 3: Implement RuleValidationError**

```swift
// Sources/PiqleyCore/Validation/RuleValidationError.swift

/// Validation errors for rule construction, with user-facing messages.
public enum RuleValidationError: Error, LocalizedError, Sendable, Equatable {
    case emptyField
    case invalidPattern(String, underlying: Error)
    case unknownAction(String)
    case missingValues(action: String)
    case missingSource
    case conflictingFields(action: String)
    case noMatch
    case noActions

    public var errorDescription: String? {
        switch self {
        case .emptyField:
            "The field name is empty."
        case let .invalidPattern(pattern, underlying):
            "The pattern \"\(pattern)\" is not valid: \(underlying.localizedDescription)"
        case let .unknownAction(action):
            "Unknown action \"\(action)\"."
        case let .missingValues(action):
            "The \"\(action)\" action requires values."
        case .missingSource:
            "The clone action requires a source."
        case let .conflictingFields(action):
            "The \"\(action)\" action has conflicting fields — use either values or replacements, not both."
        case .noMatch:
            "No match condition has been set."
        case .noActions:
            "The rule has no emit or write actions."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyField:
            "Enter a field name, or select one from the list."
        case .invalidPattern:
            "Check the pattern syntax. Use plain text for exact match, prefix with \"glob:\" for wildcards, or \"regex:\" for regular expressions."
        case .unknownAction:
            "Use one of: add, remove, replace, removeField, or clone."
        case let .missingValues(action):
            if action == "replace" {
                return "Add at least one pattern \u{2192} replacement pair."
            }
            return "Provide at least one value."
        case .missingSource:
            "Specify the source as \"source:field\" (e.g. \"exif-tagger:keywords\") or use \"*\" to clone all fields from a source."
        case let .conflictingFields(action):
            if action == "replace" {
                return "The replace action uses replacements, not values."
            }
            return "The \(action) action uses values, not replacements."
        case .noMatch:
            "Go back and set a match condition (source + field + pattern)."
        case .noActions:
            "Add at least one emit or write action."
        }
    }

    // Equatable conformance (underlying Error is not Equatable)
    public static func == (lhs: RuleValidationError, rhs: RuleValidationError) -> Bool {
        switch (lhs, rhs) {
        case (.emptyField, .emptyField): true
        case let (.invalidPattern(l, _), .invalidPattern(r, _)): l == r
        case let (.unknownAction(l), .unknownAction(r)): l == r
        case let (.missingValues(l), .missingValues(r)): l == r
        case (.missingSource, .missingSource): true
        case let (.conflictingFields(l), .conflictingFields(r)): l == r
        case (.noMatch, .noMatch): true
        case (.noActions, .noActions): true
        default: false
        }
    }
}
```

- [ ] **Step 4: Implement RuleValidator**

```swift
// Sources/PiqleyCore/Validation/RuleValidator.swift
import Foundation

/// Shared validation logic for rule construction.
/// Used by RuleBuilder (Core) and RuleEvaluator (CLI).
public enum RuleValidator {

    /// Known emit/write actions.
    public static let validActions = ["add", "remove", "replace", "removeField", "clone"]

    /// Validate a match configuration.
    public static func validateMatch(field: String, pattern: String) -> Result<Void, RuleValidationError> {
        guard !field.isEmpty else {
            return .failure(.emptyField)
        }

        // Validate pattern syntax
        if pattern.hasPrefix(PatternPrefix.regex) {
            let regexPattern = String(pattern.dropFirst(PatternPrefix.regex.count))
            do {
                _ = try Regex(regexPattern)
            } catch {
                return .failure(.invalidPattern(pattern, underlying: error))
            }
        }
        // Glob and exact patterns are always syntactically valid.

        return .success(())
    }

    /// Validate an emit or write configuration.
    public static func validateEmit(_ config: EmitConfig) -> Result<Void, RuleValidationError> {
        guard !config.field.isEmpty else {
            return .failure(.emptyField)
        }

        let actionStr = config.action ?? "add"

        guard validActions.contains(actionStr) else {
            return .failure(.unknownAction(actionStr))
        }

        switch actionStr {
        case "add", "remove":
            if config.replacements != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            if config.source != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            guard let values = config.values, !values.isEmpty else {
                return .failure(.missingValues(action: actionStr))
            }

        case "replace":
            if config.values != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            if config.source != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            guard let replacements = config.replacements, !replacements.isEmpty else {
                return .failure(.missingValues(action: actionStr))
            }

        case "removeField":
            if config.values != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            if config.replacements != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            if config.source != nil {
                return .failure(.conflictingFields(action: actionStr))
            }

        case "clone":
            guard let source = config.source, !source.isEmpty else {
                return .failure(.missingSource)
            }
            if config.values != nil {
                return .failure(.conflictingFields(action: actionStr))
            }
            if config.replacements != nil {
                return .failure(.conflictingFields(action: actionStr))
            }

        default:
            return .failure(.unknownAction(actionStr))
        }

        return .success(())
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleValidation 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Validation/RuleValidationError.swift Sources/PiqleyCore/Validation/RuleValidator.swift Tests/PiqleyCoreTests/RuleValidationTests.swift
git commit -m "feat: add RuleValidationError and RuleValidator"
```

---

## Task 3: FieldInfo + MetadataFieldCatalog (PiqleyCore)

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/RuleEditing/FieldInfo.swift`
- Create: `piqley-core/Sources/PiqleyCore/RuleEditing/MetadataFieldCatalog.swift`
- Test: `piqley-core/Tests/PiqleyCoreTests/MetadataFieldCatalogTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/PiqleyCoreTests/MetadataFieldCatalogTests.swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("MetadataFieldCatalog")
struct MetadataFieldCatalogTests {

    @Test("EXIF fields are non-empty and contain common fields")
    func exifFields() {
        #expect(!MetadataFieldCatalog.exifFields.isEmpty)
        #expect(MetadataFieldCatalog.exifFields.contains("EXIF:ISO"))
        #expect(MetadataFieldCatalog.exifFields.contains("EXIF:LensModel"))
        #expect(MetadataFieldCatalog.exifFields.contains("EXIF:FocalLength"))
        #expect(MetadataFieldCatalog.exifFields.contains("EXIF:DateTimeOriginal"))
    }

    @Test("IPTC fields are non-empty and contain common fields")
    func iptcFields() {
        #expect(!MetadataFieldCatalog.iptcFields.isEmpty)
        #expect(MetadataFieldCatalog.iptcFields.contains("IPTC:Keywords"))
    }

    @Test("TIFF fields are non-empty and contain common fields")
    func tiffFields() {
        #expect(!MetadataFieldCatalog.tiffFields.isEmpty)
        #expect(MetadataFieldCatalog.tiffFields.contains("TIFF:Model"))
        #expect(MetadataFieldCatalog.tiffFields.contains("TIFF:Make"))
    }

    @Test("fields(forSource:) returns sorted FieldInfo array")
    func fieldsForSource() {
        let fields = MetadataFieldCatalog.fields(forSource: "original")
        #expect(!fields.isEmpty)

        // All should have source = "original"
        for field in fields {
            #expect(field.source == "original")
        }

        // Should be sorted by category then name
        for i in 0 ..< fields.count - 1 {
            let a = fields[i]
            let b = fields[i + 1]
            if a.category == b.category {
                #expect(a.name <= b.name, "Fields not alphabetically sorted within category")
            } else {
                #expect(a.category < b.category, "Fields not sorted by category")
            }
        }
    }

    @Test("FieldInfo qualifiedName is source:name")
    func qualifiedName() {
        let fields = MetadataFieldCatalog.fields(forSource: "read")
        if let first = fields.first {
            #expect(first.qualifiedName == "read:\(first.name)")
        }
    }

    @Test("FieldCategory sort order: custom < exif < iptc < xmp < tiff")
    func categorySortOrder() {
        #expect(FieldCategory.custom < .exif)
        #expect(FieldCategory.exif < .iptc)
        #expect(FieldCategory.iptc < .xmp)
        #expect(FieldCategory.xmp < .tiff)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter MetadataFieldCatalog 2>&1 | tail -5`
Expected: Compilation errors.

- [ ] **Step 3: Implement FieldInfo + FieldCategory**

```swift
// Sources/PiqleyCore/RuleEditing/FieldInfo.swift

/// Information about a metadata field available for rule matching.
public struct FieldInfo: Sendable, Equatable {
    /// The field name (e.g. "TIFF:Model", "keywords").
    public let name: String
    /// The source this field belongs to (e.g. "original", "exif-tagger").
    public let source: String
    /// The fully qualified name (e.g. "original:TIFF:Model").
    public let qualifiedName: String
    /// The category for sorting purposes.
    public let category: FieldCategory

    public init(name: String, source: String, qualifiedName: String, category: FieldCategory) {
        self.name = name
        self.source = source
        self.qualifiedName = qualifiedName
        self.category = category
    }

    /// Convenience initializer that builds qualifiedName from source + name.
    public init(name: String, source: String, category: FieldCategory) {
        self.name = name
        self.source = source
        self.qualifiedName = "\(source):\(name)"
        self.category = category
    }
}

/// Category of a metadata field, used for display sorting.
/// Sort order: custom fields first, then EXIF, IPTC, XMP, TIFF last.
public enum FieldCategory: Int, Sendable, Comparable, CaseIterable {
    case custom = 0
    case exif = 1
    case iptc = 2
    case xmp = 3
    case tiff = 4

    public static func < (lhs: FieldCategory, rhs: FieldCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

- [ ] **Step 4: Implement MetadataFieldCatalog**

```swift
// Sources/PiqleyCore/RuleEditing/MetadataFieldCatalog.swift

/// Hardcoded catalog of common image metadata fields.
/// Used by rule editing to offer field selection without scanning actual images.
public enum MetadataFieldCatalog {

    public static let exifFields: [String] = [
        "EXIF:ApertureValue",
        "EXIF:BrightnessValue",
        "EXIF:ColorSpace",
        "EXIF:DateTimeDigitized",
        "EXIF:DateTimeOriginal",
        "EXIF:ExposureBiasValue",
        "EXIF:ExposureMode",
        "EXIF:ExposureProgram",
        "EXIF:ExposureTime",
        "EXIF:Flash",
        "EXIF:FNumber",
        "EXIF:FocalLength",
        "EXIF:FocalLengthIn35mmFilm",
        "EXIF:ISO",
        "EXIF:LensModel",
        "EXIF:LensSpecification",
        "EXIF:MeteringMode",
        "EXIF:PixelXDimension",
        "EXIF:PixelYDimension",
        "EXIF:SceneType",
        "EXIF:ShutterSpeedValue",
        "EXIF:WhiteBalance",
    ]

    public static let iptcFields: [String] = [
        "IPTC:Caption",
        "IPTC:City",
        "IPTC:Copyright",
        "IPTC:Country",
        "IPTC:Credit",
        "IPTC:DateCreated",
        "IPTC:Headline",
        "IPTC:Keywords",
        "IPTC:ObjectName",
        "IPTC:Province",
        "IPTC:Source",
        "IPTC:SpecialInstructions",
        "IPTC:Writer",
    ]

    public static let xmpFields: [String] = [
        "XMP:CreateDate",
        "XMP:CreatorTool",
        "XMP:Label",
        "XMP:ModifyDate",
        "XMP:Rating",
        "XMP:Subject",
        "XMP:Title",
    ]

    public static let tiffFields: [String] = [
        "TIFF:Artist",
        "TIFF:Copyright",
        "TIFF:DateTime",
        "TIFF:ImageDescription",
        "TIFF:Make",
        "TIFF:Model",
        "TIFF:Orientation",
        "TIFF:ResolutionUnit",
        "TIFF:Software",
        "TIFF:XResolution",
        "TIFF:YResolution",
    ]

    /// Build FieldInfo array for a source, sorted by category then name.
    public static func fields(forSource source: String) -> [FieldInfo] {
        var result: [FieldInfo] = []
        for name in exifFields {
            result.append(FieldInfo(name: name, source: source, category: .exif))
        }
        for name in iptcFields {
            result.append(FieldInfo(name: name, source: source, category: .iptc))
        }
        for name in xmpFields {
            result.append(FieldInfo(name: name, source: source, category: .xmp))
        }
        for name in tiffFields {
            result.append(FieldInfo(name: name, source: source, category: .tiff))
        }
        return result.sorted { a, b in
            if a.category != b.category { return a.category < b.category }
            return a.name < b.name
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter MetadataFieldCatalog 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/RuleEditing/ Tests/PiqleyCoreTests/MetadataFieldCatalogTests.swift
git commit -m "feat: add FieldInfo, FieldCategory, and MetadataFieldCatalog"
```

---

## Task 4: RuleEditingContext (PiqleyCore)

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/RuleEditing/RuleEditingContext.swift`
- Test: `piqley-core/Tests/PiqleyCoreTests/RuleEditingContextTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/PiqleyCoreTests/RuleEditingContextTests.swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("RuleEditingContext")
struct RuleEditingContextTests {

    private func makeContext() -> RuleEditingContext {
        let originalFields = MetadataFieldCatalog.fields(forSource: "original")
        let depFields = [
            FieldInfo(name: "scene", source: "exif-tagger", category: .custom),
            FieldInfo(name: "lens-class", source: "exif-tagger", category: .custom),
        ]
        let sampleRule = Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "Sony"),
            emit: [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]
        )
        let stage = StageConfig(
            preRules: [sampleRule],
            binary: HookConfig(command: "./bin/test"),
            postRules: nil
        )
        return RuleEditingContext(
            availableFields: [
                "original": originalFields,
                "read": MetadataFieldCatalog.fields(forSource: "read"),
                "exif-tagger": depFields,
            ],
            pluginIdentifier: "com.test.plugin",
            stages: ["pre-process": stage]
        )
    }

    @Test("availableSources returns all source names")
    func availableSources() {
        let ctx = makeContext()
        let sources = ctx.availableSources()
        #expect(sources.contains("original"))
        #expect(sources.contains("read"))
        #expect(sources.contains("exif-tagger"))
    }

    @Test("fields(in:) returns sorted fields for known source")
    func fieldsInSource() {
        let ctx = makeContext()
        let fields = ctx.fields(in: "exif-tagger")
        #expect(fields.count == 2)
        #expect(fields[0].name == "lens-class") // alphabetical within custom
        #expect(fields[1].name == "scene")
    }

    @Test("fields(in:) returns empty for unknown source")
    func fieldsInUnknownSource() {
        let ctx = makeContext()
        #expect(ctx.fields(in: "nonexistent").isEmpty)
    }

    @Test("validActions returns all five actions")
    func validActions() {
        let ctx = makeContext()
        let actions = ctx.validActions()
        #expect(actions.count == 5)
        #expect(actions.contains("add"))
        #expect(actions.contains("clone"))
    }

    @Test("stageNames returns loaded stages")
    func stageNames() {
        let ctx = makeContext()
        #expect(ctx.stageNames().contains("pre-process"))
    }

    @Test("rules(forStage:slot:) returns existing rules")
    func rulesForStage() {
        let ctx = makeContext()
        let rules = ctx.rules(forStage: "pre-process", slot: .pre)
        #expect(rules.count == 1)
        #expect(rules[0].match.field == "original:TIFF:Model")
    }

    @Test("rules for empty slot returns empty array")
    func rulesForEmptySlot() {
        let ctx = makeContext()
        #expect(ctx.rules(forStage: "pre-process", slot: .post).isEmpty)
    }

    @Test("stageHasBinary returns true when binary configured")
    func hasBinary() {
        let ctx = makeContext()
        #expect(ctx.stageHasBinary("pre-process"))
    }

    @Test("stageHasBinary returns false for unknown stage")
    func noBinaryUnknownStage() {
        let ctx = makeContext()
        #expect(!ctx.stageHasBinary("nonexistent"))
    }

    @Test("validateMatch delegates to RuleValidator")
    func validateMatch() {
        let ctx = makeContext()
        #expect(ctx.validateMatch(field: "original:TIFF:Model", pattern: "Sony") == .success(()))
        if case .failure(.emptyField) = ctx.validateMatch(field: "", pattern: "Sony") {} else {
            Issue.record("Expected emptyField failure")
        }
    }

    @Test("validateEmit delegates to RuleValidator")
    func validateEmit() {
        let ctx = makeContext()
        let good = EmitConfig(action: "add", field: "keywords", values: ["a"], replacements: nil, source: nil)
        #expect(ctx.validateEmit(good) == .success(()))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleEditingContext 2>&1 | tail -5`
Expected: Compilation errors.

- [ ] **Step 3: Implement RuleEditingContext**

```swift
// Sources/PiqleyCore/RuleEditing/RuleEditingContext.swift

/// Context for rule editing operations. The client injects available fields
/// and stage data; the context provides queries and validation.
public struct RuleEditingContext: Sendable {
    /// Available fields organized by source name.
    public let availableFields: [String: [FieldInfo]]

    /// The plugin being edited.
    public let pluginIdentifier: String

    /// Existing stages and their rules.
    public var stages: [String: StageConfig]

    public init(
        availableFields: [String: [FieldInfo]],
        pluginIdentifier: String,
        stages: [String: StageConfig]
    ) {
        self.availableFields = availableFields
        self.pluginIdentifier = pluginIdentifier
        self.stages = stages
    }

    /// Source names available for matching.
    public func availableSources() -> [String] {
        Array(availableFields.keys).sorted()
    }

    /// Fields within a source, sorted: custom -> EXIF -> IPTC -> XMP -> TIFF, then alphabetically.
    public func fields(in source: String) -> [FieldInfo] {
        guard let fields = availableFields[source] else { return [] }
        return fields.sorted { a, b in
            if a.category != b.category { return a.category < b.category }
            return a.name < b.name
        }
    }

    /// The five known emit/write actions.
    public func validActions() -> [String] {
        RuleValidator.validActions
    }

    /// Stage names that have stage files for this plugin.
    public func stageNames() -> [String] {
        Array(stages.keys).sorted()
    }

    /// Existing rules in a stage/slot.
    public func rules(forStage stage: String, slot: RuleSlot) -> [Rule] {
        guard let stageConfig = stages[stage] else { return [] }
        switch slot {
        case .pre: return stageConfig.preRules ?? []
        case .post: return stageConfig.postRules ?? []
        }
    }

    /// Whether a stage has a binary configured.
    public func stageHasBinary(_ stage: String) -> Bool {
        stages[stage]?.binary != nil
    }

    /// Validate a match configuration.
    public func validateMatch(field: String, pattern: String) -> Result<Void, RuleValidationError> {
        RuleValidator.validateMatch(field: field, pattern: pattern)
    }

    /// Validate an emit/write configuration.
    public func validateEmit(_ config: EmitConfig) -> Result<Void, RuleValidationError> {
        RuleValidator.validateEmit(config)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleEditingContext 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Run full Core suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/RuleEditing/RuleEditingContext.swift Tests/PiqleyCoreTests/RuleEditingContextTests.swift
git commit -m "feat: add RuleEditingContext with query and validation methods"
```

---

## Task 5: RuleBuilder (PiqleyCore)

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/RuleEditing/RuleBuilder.swift`
- Test: `piqley-core/Tests/PiqleyCoreTests/RuleBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/PiqleyCoreTests/RuleBuilderTests.swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("RuleBuilder")
struct RuleBuilderTests {

    private func makeContext() -> RuleEditingContext {
        RuleEditingContext(
            availableFields: ["original": MetadataFieldCatalog.fields(forSource: "original")],
            pluginIdentifier: "com.test.plugin",
            stages: [:]
        )
    }

    @Test("full build flow succeeds")
    func fullBuild() throws {
        var builder = RuleBuilder(context: makeContext())
        let matchResult = builder.setMatch(field: "original:TIFF:Model", pattern: "Sony")
        #expect(matchResult == .success(()))

        let emitResult = builder.addEmit(
            EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)
        )
        #expect(emitResult == .success(()))

        let rule = try builder.build().get()
        #expect(rule.match.field == "original:TIFF:Model")
        #expect(rule.match.pattern == "Sony")
        #expect(rule.emit.count == 1)
        #expect(rule.write.isEmpty)
    }

    @Test("build with emit and write actions")
    func buildWithBoth() throws {
        var builder = RuleBuilder(context: makeContext())
        _ = builder.setMatch(field: "original:TIFF:Model", pattern: "Canon")
        _ = builder.addEmit(
            EmitConfig(action: nil, field: "keywords", values: ["canon"], replacements: nil, source: nil)
        )
        _ = builder.addWrite(
            EmitConfig(action: "add", field: "IPTC:Keywords", values: ["canon"], replacements: nil, source: nil)
        )

        let rule = try builder.build().get()
        #expect(rule.emit.count == 1)
        #expect(rule.write.count == 1)
        #expect(rule.write[0].field == "IPTC:Keywords")
    }

    @Test("setMatch validates and rejects empty field")
    func setMatchEmptyField() {
        var builder = RuleBuilder(context: makeContext())
        let result = builder.setMatch(field: "", pattern: "Sony")
        guard case .failure(.emptyField) = result else {
            Issue.record("Expected emptyField failure")
            return
        }
    }

    @Test("setMatch validates and rejects invalid regex")
    func setMatchInvalidRegex() {
        var builder = RuleBuilder(context: makeContext())
        let result = builder.setMatch(field: "original:TIFF:Model", pattern: "regex:[bad")
        guard case .failure(.invalidPattern) = result else {
            Issue.record("Expected invalidPattern failure")
            return
        }
    }

    @Test("addEmit validates and rejects unknown action")
    func addEmitUnknownAction() {
        var builder = RuleBuilder(context: makeContext())
        _ = builder.setMatch(field: "original:TIFF:Model", pattern: "Sony")
        let result = builder.addEmit(
            EmitConfig(action: "yeet", field: "keywords", values: ["a"], replacements: nil, source: nil)
        )
        guard case .failure(.unknownAction) = result else {
            Issue.record("Expected unknownAction failure")
            return
        }
    }

    @Test("build without match fails")
    func buildWithoutMatch() {
        let builder = RuleBuilder(context: makeContext())
        guard case .failure(.noMatch) = builder.build() else {
            Issue.record("Expected noMatch failure")
            return
        }
    }

    @Test("build without actions fails")
    func buildWithoutActions() {
        var builder = RuleBuilder(context: makeContext())
        _ = builder.setMatch(field: "original:TIFF:Model", pattern: "Sony")
        guard case .failure(.noActions) = builder.build() else {
            Issue.record("Expected noActions failure")
            return
        }
    }

    @Test("reset clears all state")
    func resetClearsState() {
        var builder = RuleBuilder(context: makeContext())
        _ = builder.setMatch(field: "original:TIFF:Model", pattern: "Sony")
        _ = builder.addEmit(
            EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)
        )
        builder.reset()
        guard case .failure(.noMatch) = builder.build() else {
            Issue.record("Expected noMatch after reset")
            return
        }
    }

    @Test("multiple emit actions accumulate")
    func multipleEmits() throws {
        var builder = RuleBuilder(context: makeContext())
        _ = builder.setMatch(field: "original:TIFF:Model", pattern: "Sony")
        _ = builder.addEmit(EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil))
        _ = builder.addEmit(EmitConfig(action: nil, field: "brand", values: ["sony"], replacements: nil, source: nil))

        let rule = try builder.build().get()
        #expect(rule.emit.count == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleBuilder 2>&1 | tail -5`
Expected: Compilation errors.

- [ ] **Step 3: Implement RuleBuilder**

```swift
// Sources/PiqleyCore/RuleEditing/RuleBuilder.swift

/// Fluent builder for constructing validated rules.
/// Each setter validates immediately and returns a Result.
public struct RuleBuilder: Sendable {
    private let context: RuleEditingContext
    private var match: MatchConfig?
    private var emitActions: [EmitConfig] = []
    private var writeActions: [EmitConfig] = []

    public init(context: RuleEditingContext) {
        self.context = context
    }

    /// Set the match config. Validates field and pattern syntax.
    public mutating func setMatch(field: String, pattern: String) -> Result<Void, RuleValidationError> {
        let result = context.validateMatch(field: field, pattern: pattern)
        if case .success = result {
            match = MatchConfig(field: field, pattern: pattern)
        }
        return result
    }

    /// Add an emit action. Validates the config immediately.
    public mutating func addEmit(_ config: EmitConfig) -> Result<Void, RuleValidationError> {
        let result = context.validateEmit(config)
        if case .success = result {
            emitActions.append(config)
        }
        return result
    }

    /// Add a write action. Validates the config immediately.
    public mutating func addWrite(_ config: EmitConfig) -> Result<Void, RuleValidationError> {
        let result = context.validateEmit(config)
        if case .success = result {
            writeActions.append(config)
        }
        return result
    }

    /// Reset the builder to start fresh.
    public mutating func reset() {
        match = nil
        emitActions = []
        writeActions = []
    }

    /// Build the final rule. Fails if match is not set or no actions exist.
    public func build() -> Result<Rule, RuleValidationError> {
        guard let match else {
            return .failure(.noMatch)
        }
        guard !emitActions.isEmpty || !writeActions.isEmpty else {
            return .failure(.noActions)
        }
        return .success(Rule(match: match, emit: emitActions, write: writeActions))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleBuilder 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Run full Core suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/RuleEditing/RuleBuilder.swift Tests/PiqleyCoreTests/RuleBuilderTests.swift
git commit -m "feat: add RuleBuilder with inline validation"
```

---

## Task 6: Update RuleEvaluator to Use Shared Validator (CLI)

**Files:**
- Modify: `piqley-cli/Sources/piqley/State/RuleEvaluator.swift:101-188`
- Test: existing `piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift` (regression only)

- [ ] **Step 1: Update RuleEvaluator.compileEmitAction to delegate to RuleValidator**

In `piqley-cli/Sources/piqley/State/RuleEvaluator.swift`, replace the `compileEmitAction` method body to validate via `RuleValidator.validateEmit` first, then compile. The compilation (building `EmitAction` enum values with `TagMatcher`) stays in the evaluator since that's CLI-specific. Only the validation checks move to Core.

Add a validation call at the top of `compileEmitAction`:

```swift
private static func compileEmitAction(_ config: EmitConfig, ruleIndex: Int) throws -> EmitAction {
    // Validate via shared Core validator
    if case let .failure(error) = RuleValidator.validateEmit(config) {
        throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: error.errorDescription ?? "invalid emit")
    }

    let actionStr = config.action ?? "add"
    // ... rest of compilation (building matchers, returning EmitAction) stays the same
```

Remove the duplicated validation checks from each `case` in the switch (the `guard` statements checking for nil values, conflicting fields, etc.) since `RuleValidator.validateEmit` already covers them. Keep only the compilation logic (building `TagMatcher` instances, constructing `EmitAction` values).

- [ ] **Step 2: Run full CLI test suite to check for regressions**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -10`
Expected: All tests PASS. The behavior is identical — same validations, just from a different source.

- [ ] **Step 3: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/RuleEvaluator.swift
git commit -m "refactor: delegate emit validation to shared RuleValidator"
```

---

## Task 7: Add TermKit Dependency + Command Registration (CLI)

**Files:**
- Modify: `piqley-cli/Package.swift:7-8` (add TermKit dependency)
- Create: `piqley-cli/Sources/piqley/CLI/PluginRulesCommand.swift`
- Modify: `piqley-cli/Sources/piqley/CLI/PluginCommand.swift:8` (add to subcommands)

- [ ] **Step 1: Add TermKit to Package.swift**

Add to the `dependencies` array:
```swift
.package(url: "https://github.com/migueldeicaza/TermKit.git", from: "1.0.0"),
```

Add to the executable target's dependencies:
```swift
.product(name: "TermKit", package: "TermKit"),
```

- [ ] **Step 2: Verify TermKit resolves**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift package resolve 2>&1 | tail -5`
Expected: Resolves successfully. If TermKit's version/branch differs, adjust the version requirement.

- [ ] **Step 3: Create PluginRulesCommand stub**

```swift
// Sources/piqley/CLI/PluginRulesCommand.swift
import ArgumentParser
import PiqleyCore

/// Command group: piqley plugin rules
struct PluginRulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Manage rules for a plugin.",
        subcommands: [PluginRulesEditCommand.self],
        defaultSubcommand: PluginRulesEditCommand.self
    )
}

/// Subcommand: piqley plugin rules edit <plugin-id>
struct PluginRulesEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Interactively edit rules for a plugin."
    )

    @Argument(help: "The plugin identifier to edit rules for.")
    var pluginID: String

    func run() async throws {
        print("Rule editor for \(pluginID) — not yet implemented.")
    }
}
```

- [ ] **Step 4: Register in PluginCommand**

In `piqley-cli/Sources/piqley/CLI/PluginCommand.swift`, add `PluginRulesCommand.self` to the `subcommands` array in `PluginCommand`'s `CommandConfiguration`.

- [ ] **Step 5: Verify the command appears in help**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift run piqley plugin rules --help 2>&1`
Expected: Shows "Manage rules for a plugin." with `edit` subcommand listed.

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Package.swift Sources/piqley/CLI/PluginRulesCommand.swift Sources/piqley/CLI/PluginCommand.swift
git commit -m "feat: add piqley plugin rules command group with edit stub"
```

---

## Task 8: Field Discovery (CLI)

**Files:**
- Create: `piqley-cli/Sources/piqley/Wizard/FieldDiscovery.swift`
- Test: `piqley-cli/Tests/piqleyTests/FieldDiscoveryTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/piqleyTests/FieldDiscoveryTests.swift
import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("FieldDiscovery")
struct FieldDiscoveryTests {

    @Test("builds fields for original and read sources from catalog")
    func catalogSources() {
        let fields = FieldDiscovery.buildAvailableFields(dependencies: [])
        #expect(fields["original"] != nil)
        #expect(fields["read"] != nil)
        #expect(!fields["original"]!.isEmpty)
        // All original fields should have source "original"
        for field in fields["original"]! {
            #expect(field.source == "original")
        }
    }

    @Test("includes dependency plugin fields as custom category")
    func dependencyFields() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "exif-tagger",
            fields: ["scene", "lens-class", "confidence"]
        )
        let fields = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        #expect(fields["exif-tagger"] != nil)
        #expect(fields["exif-tagger"]?.count == 3)
        for field in fields["exif-tagger"]! {
            #expect(field.category == .custom)
            #expect(field.source == "exif-tagger")
        }
    }

    @Test("dependency fields are sorted alphabetically")
    func dependencyFieldsSorted() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "my-plugin",
            fields: ["zebra", "alpha", "middle"]
        )
        let fields = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let names = fields["my-plugin"]!.map(\.name)
        #expect(names == ["alpha", "middle", "zebra"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter FieldDiscovery 2>&1 | tail -5`
Expected: Compilation errors.

- [ ] **Step 3: Implement FieldDiscovery**

```swift
// Sources/piqley/Wizard/FieldDiscovery.swift
import PiqleyCore

/// Builds the available fields map for a RuleEditingContext.
enum FieldDiscovery {

    /// Lightweight info about a dependency plugin's declared fields.
    struct DependencyInfo {
        let identifier: String
        let fields: [String]
    }

    /// Build the availableFields dictionary for a RuleEditingContext.
    /// Always includes "original" and "read" from the catalog.
    /// Adds custom fields for each dependency.
    static func buildAvailableFields(dependencies: [DependencyInfo]) -> [String: [FieldInfo]] {
        var result: [String: [FieldInfo]] = [:]

        // Standard metadata sources
        result["original"] = MetadataFieldCatalog.fields(forSource: "original")
        result["read"] = MetadataFieldCatalog.fields(forSource: "read")

        // Dependency plugin fields
        for dep in dependencies {
            let fields = dep.fields.sorted().map { name in
                FieldInfo(name: name, source: dep.identifier, category: .custom)
            }
            result[dep.identifier] = fields
        }

        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter FieldDiscovery 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Wizard/FieldDiscovery.swift Tests/piqleyTests/FieldDiscoveryTests.swift
git commit -m "feat: add FieldDiscovery for building available fields map"
```

---

## Task 9: TUI Wizard — Stage Select + Rule List Screens (CLI)

**Files:**
- Create: `piqley-cli/Sources/piqley/Wizard/RulesWizardApp.swift`
- Create: `piqley-cli/Sources/piqley/Wizard/StageSelectScreen.swift`
- Create: `piqley-cli/Sources/piqley/Wizard/RuleListScreen.swift`

This task creates the TermKit application shell and the first two screens. Detailed TermKit widget code depends on the TermKit API — the implementer should consult TermKit's documentation and examples. The structure below provides the architecture; adapt widget calls to TermKit's actual API.

- [ ] **Step 1: Create RulesWizardApp entry point**

```swift
// Sources/piqley/Wizard/RulesWizardApp.swift
import TermKit
import PiqleyCore

/// Entry point for the TUI rule editor wizard.
/// Manages the TermKit Application lifecycle and screen navigation.
enum RulesWizardApp {

    /// Launch the wizard. Returns the modified stages (or nil if cancelled).
    static func run(context: RuleEditingContext) -> [String: StageConfig]? {
        Application.prepare()

        let result = StageSelectScreen.show(context: context)

        Application.shutdown()
        return result
    }
}
```

- [ ] **Step 2: Create StageSelectScreen**

```swift
// Sources/piqley/Wizard/StageSelectScreen.swift
import TermKit
import PiqleyCore

/// Screen: select which stage to edit rules for.
/// Shows stage names with rule counts.
enum StageSelectScreen {

    static func show(context: RuleEditingContext) -> [String: StageConfig]? {
        var context = context
        let stageNames = context.stageNames()

        // Build list items with rule counts
        // Use TermKit Frame + ListView
        // Navigation: arrow keys to select, Enter to open, q to quit

        // On selection: navigate to RuleListScreen for chosen stage
        // On return from RuleListScreen: update context.stages with changes
        // Loop until user presses q

        // Return modified stages or nil if cancelled
        return context.stages
    }
}
```

The implementer should:
- Create a `Frame` with title "Edit Rules: \(context.pluginIdentifier)"
- Create a `ListView` with stage names + rule counts (e.g. "pre-process (3 rules)")
- Handle Enter key → `RuleListScreen.show(context:stageName:)`
- Handle `q` key → return
- Show footer with "↑↓ navigate  ⏎ select  q quit"

- [ ] **Step 3: Create RuleListScreen with filtering**

```swift
// Sources/piqley/Wizard/RuleListScreen.swift
import TermKit
import PiqleyCore

/// Screen: list rules for a stage with filtering and action keys.
enum RuleListScreen {

    static func show(context: inout RuleEditingContext, stageName: String) {
        let hasBinary = context.stageHasBinary(stageName)
        // If no binary, all rules are pre-rules — don't show slot choice

        // Build rule display strings from context.rules(forStage:slot:)
        // Format: "source:field ~ pattern → action summary"

        // TermKit layout:
        // - Frame with title "stageName rules"
        // - Optional TextField for filter (activated by 'f' key)
        // - ListView of rules with paging (pgup/pgdn)
        // - Footer: "↑↓ navigate  ⏎ select  f filter  a add  e edit  d delete  r reorder  q back"

        // Filter behavior:
        // - 'f' activates filter TextField at top
        // - Keystrokes immediately filter the list (case-insensitive substring match)
        // - Esc clears filter
        // - Filter matches against: source:field, pattern, action summary

        // Actions:
        // - 'a' → RuleEditorScreen.show(context:stageName:slot:editingIndex:nil)
        // - 'e' on selected rule → RuleEditorScreen.show(context:stageName:slot:editingIndex:index)
        // - 'd' on selected rule → confirm and call context.stages[stageName].removeRule(...)
        // - 'r' → enter reorder mode (move selected rule with arrow keys, Enter to confirm)
    }
}
```

- [ ] **Step 4: Verify the app compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Compiles. These are stubs — no runtime behavior to test yet.

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Wizard/
git commit -m "feat: add TUI wizard shell with stage select and rule list screens"
```

---

## Task 10: TUI Wizard — Rule Editor Screen (CLI)

**Files:**
- Create: `piqley-cli/Sources/piqley/Wizard/RuleEditorScreen.swift`

- [ ] **Step 1: Create RuleEditorScreen**

```swift
// Sources/piqley/Wizard/RuleEditorScreen.swift
import TermKit
import PiqleyCore

/// Screen: multi-step rule creation/editing with pinned context.
/// Steps: source → field → pattern → emit actions → write actions → confirm
enum RuleEditorScreen {

    /// Show the rule editor. Returns the built Rule or nil if cancelled.
    /// If editingIndex is non-nil, pre-populates from the existing rule.
    static func show(
        context: RuleEditingContext,
        stageName: String,
        slot: RuleSlot,
        editingIndex: Int?
    ) -> Rule? {
        var builder = RuleBuilder(context: context)

        // If editing, pre-populate builder from existing rule
        if let index = editingIndex {
            let existing = context.rules(forStage: stageName, slot: slot)[index]
            _ = builder.setMatch(field: existing.match.field, pattern: existing.match.pattern)
            for emit in existing.emit { _ = builder.addEmit(emit) }
            for write in existing.write { _ = builder.addWrite(write) }
        }

        // Step 1: Source selection
        // - Show ListView of context.availableSources() with descriptions
        // - "original" → "file metadata (available at load)"
        // - "read" → "file metadata (loaded on demand)"
        // - dependency names → "dependency plugin"

        // Step 2: Field selection
        // - Show grouped ListView: fields sorted by category with section headers
        // - Support 'f' filter and 't' for custom field name
        // - Pinned at top: "Match: {source}:▌"

        // Step 3: Pattern input
        // - TextField for pattern entry
        // - Hint text: "Plain text = exact match. Prefix with glob: or regex: for advanced."
        // - On Enter: call builder.setMatch() — show error inline if invalid, retry
        // - Pinned at top: "Match: {source}:{field} ~ ▌"

        // Step 4: Emit actions
        // - Pinned: "Match: {qualified_field} ~ {pattern}"
        // - Loop: show action menu (add/remove/replace/removeField/clone)
        // - For each action: collect detail input (field, values/replacements/source)
        // - Call builder.addEmit() — show error inline if invalid
        // - After each: "Add another emit action? (y/N)"

        // Step 5: Write actions
        // - Pinned: match + emit summary
        // - Same flow as emit, with "skip — no write actions" option
        // - Call builder.addWrite()

        // Step 6: Confirm
        // - Show full summary (match, all emits, all writes)
        // - Options: s (save), e (edit — go back), c (cancel)
        // - On save: return builder.build().get()

        // All validation errors display inline below input:
        // - errorDescription in red/bold
        // - recoverySuggestion in dim text
        // - User retries without losing position

        return nil // placeholder
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Compiles.

- [ ] **Step 3: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Wizard/RuleEditorScreen.swift
git commit -m "feat: add rule editor screen with multi-step flow"
```

---

## Task 11: Wire Up the Edit Command (CLI)

**Files:**
- Modify: `piqley-cli/Sources/piqley/CLI/PluginRulesCommand.swift`

- [ ] **Step 1: Implement the edit command's run method**

Replace the stub `run()` in `PluginRulesEditCommand`:

```swift
func run() async throws {
    // 1. Resolve plugin directory
    let pluginDir = PiqleyPath.pluginsDirectory.appendingPathComponent(pluginID)
    guard FileManager.default.fileExists(atPath: pluginDir.path) else {
        throw ValidationError("Plugin '\(pluginID)' not found at \(pluginDir.path)")
    }

    // 2. Load manifest
    let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

    // 3. Load stages
    let stages = try PluginDiscovery.loadStages(
        from: pluginDir,
        knownHooks: Set(Hook.allCases.map(\.rawValue)),
        logger: .init(label: "piqley.rules")
    )

    // 4. Build dependency info
    var deps: [FieldDiscovery.DependencyInfo] = []
    for depID in manifest.dependencyIdentifiers {
        let depDir = PluginDirectory.pluginRoot(for: depID)
        let depManifestURL = depDir.appendingPathComponent(PluginFile.manifest)
        if let depData = try? Data(contentsOf: depManifestURL),
           let depManifest = try? JSONDecoder().decode(PluginManifest.self, from: depData) {
            // Use config value keys as declared fields (best available proxy)
            let fields = depManifest.valueEntries.map(\.key)
            deps.append(FieldDiscovery.DependencyInfo(identifier: depID, fields: fields))
        }
    }

    // 5. Build context
    let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
    let context = RuleEditingContext(
        availableFields: availableFields,
        pluginIdentifier: pluginID,
        stages: stages
    )

    // 6. Launch wizard
    guard let modifiedStages = RulesWizardApp.run(context: context) else {
        print("Cancelled.")
        return
    }

    // 7. Write modified stages back
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (hookName, stageConfig) in modifiedStages {
        let data = try encoder.encode(stageConfig)
        let stageFile = pluginDir.appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")
        // Atomic write (writes to temp file internally, then renames)
        try data.write(to: stageFile, options: .atomic)
    }

    print("Rules saved.")
}
```

Note: The implementer should verify exact method signatures for `PluginDiscovery.loadStages` and `PiqleyPath.pluginsDirectory` — adapt the calls to match the actual codebase API.

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Compiles. May need minor adjustments to match actual API signatures.

- [ ] **Step 3: Manual smoke test**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift run piqley plugin rules edit com.nonexistent.plugin 2>&1`
Expected: "Plugin 'com.nonexistent.plugin' not found" error message.

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/CLI/PluginRulesCommand.swift
git commit -m "feat: wire up rules edit command with field discovery and stage I/O"
```

---

## Task 12: Implement TUI Screens (CLI)

This is the largest task — filling in the TermKit widget code for all three screens. The implementer should work through each screen sequentially, testing manually after each.

**Files:**
- Modify: `piqley-cli/Sources/piqley/Wizard/StageSelectScreen.swift`
- Modify: `piqley-cli/Sources/piqley/Wizard/RuleListScreen.swift`
- Modify: `piqley-cli/Sources/piqley/Wizard/RuleEditorScreen.swift`
- Modify: `piqley-cli/Sources/piqley/Wizard/RulesWizardApp.swift`

- [ ] **Step 1: Implement StageSelectScreen with TermKit**

Fill in the `StageSelectScreen.show` method:
- Create a `Window` with bordered frame
- Add a `ListView` populated with stage names + rule counts
- Handle keyboard: Enter to select, q to quit
- Footer `Label` with navigation hints
- On selection, call `RuleListScreen.show`

Consult TermKit README and examples for `Application.prepare()`, `Window`, `ListView`, keyboard handling patterns.

- [ ] **Step 2: Manual test — stage selection**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift run piqley plugin rules edit <an-installed-plugin-id>`
Expected: Full-screen TUI showing stages. Arrow keys navigate, Enter opens, q quits.

- [ ] **Step 3: Implement RuleListScreen with filtering**

Fill in `RuleListScreen.show`:
- Build display strings for each rule: `"source:field ~ pattern → action summary"`
- `ListView` with paging support
- `TextField` for filter (toggled by 'f')
- Live filtering: on each keystroke, rebuild the filtered data source
- Action keys: a/e/d/r with corresponding behaviors
- Handle the "no binary → skip slot choice" logic

- [ ] **Step 4: Manual test — rule list with filter**

Expected: Rules display correctly, 'f' activates filter, typing filters live, Esc clears, pgup/pgdn pages through large lists.

- [ ] **Step 5: Implement RuleEditorScreen steps**

Fill in `RuleEditorScreen.show` with the full multi-step flow:
- Source selection (ListView)
- Field selection (grouped ListView with category headers + filter)
- Pattern input (TextField with inline validation)
- Emit action loop (action menu → detail input → validate → repeat)
- Write action loop (same, with skip option)
- Confirm screen (summary + save/edit/cancel)
- Pinned context label updates at each step

- [ ] **Step 6: Manual test — full rule creation flow**

Expected: Can create a complete rule through all steps. Match context stays pinned. Validation errors display inline with recovery suggestions. Save writes to disk.

- [ ] **Step 7: Manual test — edit existing rule**

Expected: Selecting an existing rule and pressing 'e' pre-populates the editor. Changes save correctly.

- [ ] **Step 8: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Wizard/
git commit -m "feat: implement TUI wizard screens with TermKit"
```

---

## Task 13: Full Integration Test + Polish (CLI)

- [ ] **Step 1: Run full CLI test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 2: Run full Core test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 3: End-to-end manual test**

Test the full flow with an actual installed plugin:
1. `piqley plugin rules edit <plugin-id>` — opens TUI
2. Select a stage
3. View existing rules, filter them
4. Add a new rule (all steps)
5. Edit an existing rule
6. Delete a rule
7. Verify the stage JSON file was written correctly

- [ ] **Step 4: Commit any polish**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add -A
git commit -m "polish: rule editor wizard cleanup and integration fixes"
```
