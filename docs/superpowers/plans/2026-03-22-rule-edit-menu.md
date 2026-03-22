# Rule Edit Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sequential step-by-step edit flow in the rules wizard with a navigable menu that lets users edit individual rule components.

**Architecture:** The top-level `editRuleMenu` shows field, pattern, negated, and all actions as menu items. Selecting an action opens an `editAction` sub-menu showing that action's editable parts. State is held as mutable locals and validated through `RuleBuilder` on save. A `setMatch(field:pattern:not:)` overload is added to `RuleBuilder` to support the negation toggle.

**Tech Stack:** Swift, PiqleyCore (RuleBuilder/RuleValidator), RawTerminal TUI primitives

**Spec:** `docs/superpowers/specs/2026-03-22-rule-edit-menu-design.md`

---

### Task 1: Add `setMatch(field:pattern:not:)` overload to RuleBuilder

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/RuleEditing/RuleBuilder.swift:30-37`
- Test: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/RuleBuilderTests.swift`

- [ ] **Step 1: Write failing test for setMatch with not parameter**

In `RuleBuilderTests.swift`, add after the existing `setMatchReplacesExistingMatch` test:

```swift
@Test func setMatchWithNotFlagPreservesNegation() {
    var builder = RuleBuilder(context: makeContext())
    let result = builder.setMatch(field: "Keywords", pattern: "portrait", not: true)
    #expect(isSuccess(result))
    _ = builder.addEmit(makeEmit())

    let buildResult = builder.build()
    if case .success(let rule) = buildResult {
        #expect(rule.match.not == true)
    } else {
        Issue.record("Expected .success, got \(buildResult)")
    }
}

@Test func setMatchWithNotNilOmitsFlag() {
    var builder = RuleBuilder(context: makeContext())
    _ = builder.setMatch(field: "Keywords", pattern: "portrait", not: nil)
    _ = builder.addEmit(makeEmit())

    let buildResult = builder.build()
    if case .success(let rule) = buildResult {
        #expect(rule.match.not == nil)
    } else {
        Issue.record("Expected .success, got \(buildResult)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleBuilderTests 2>&1 | tail -20`
Expected: Compilation error, `setMatch` has no `not` parameter

- [ ] **Step 3: Add the overload to RuleBuilder**

In `RuleBuilder.swift`, add after the existing `setMatch(field:pattern:)` method (after line 37):

```swift
/// Validates and stores a match configuration with an optional negation flag.
///
/// On success the match is stored and replaces any previously stored match.
/// On failure the match state is unchanged.
@discardableResult
public mutating func setMatch(field: String, pattern: String, not: Bool?) -> Result<Void, RuleValidationError> {
    let result = context.validateMatch(field: field, pattern: pattern)
    if case .success = result {
        match = MatchConfig(field: field, pattern: pattern, not: not)
    }
    return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter RuleBuilderTests 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```
git add Sources/PiqleyCore/RuleEditing/RuleBuilder.swift Tests/PiqleyCoreTests/RuleBuilderTests.swift
git commit -m "feat: add setMatch(field:pattern:not:) overload to RuleBuilder"
```

---

### Task 2: Add `formatEmitAction` helper to RulesWizard+UI

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard+UI.swift:142-163`

- [ ] **Step 1: Add the formatEmitAction method**

In `RulesWizard+UI.swift`, add inside the `extension RulesWizard` block, before the closing `}`, after `formatRule`:

```swift
/// Formats a single emit/write action for display in the edit menu.
func formatEmitAction(_ emit: EmitConfig) -> String {
    let action = emit.action ?? "add"
    let target = emit.field ?? "keywords"
    switch action {
    case "add", "remove":
        let vals = emit.values?.joined(separator: ", ") ?? ""
        return "\(action) \(target)=[\(vals)]"
    case "replace":
        if let replacements = emit.replacements {
            let pairs = replacements.map { "\($0.pattern)\u{2192}\($0.replacement)" }
            return "replace \(target) [\(pairs.joined(separator: ", "))]"
        }
        return "replace \(target)"
    case "clone":
        return "clone \(target) from \(emit.source ?? "?")"
    case "removeField":
        return "removeField \(target)"
    default:
        return "\(action) \(target)"
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```
git add Sources/piqley/Wizard/RulesWizard+UI.swift
git commit -m "feat: add formatEmitAction helper for rule edit menu"
```

---

### Task 3: Extract `selectField()` and `buildFieldCompletions()` helpers

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard.swift:294-319` (selectField extraction), `393-418` (field completions extraction)

- [ ] **Step 1: Add the selectField helper method**

In `RulesWizard.swift`, add after the `buildRule` method (after the closing `}` of `buildRule`, before `addActions`):

```swift
/// Prompts for source then field selection. Returns the qualified name and display name,
/// or nil if the user cancels.
private func selectField() -> (qualifiedName: String, displayName: String)? {
    let sources = context.availableSources()
    let sourceItems = sources.map { source -> String in
        switch source {
        case "original": return "\(source)  \(ANSI.dim)\u{2014} file metadata loaded at import\(ANSI.reset)"
        case "read": return "\(source)  \(ANSI.dim)\u{2014} file metadata loaded on demand\(ANSI.reset)"
        default: return "\(source)  \(ANSI.dim)\u{2014} dependency plugin\(ANSI.reset)"
        }
    }
    guard let sourceIdx = terminal.selectFromList(
        title: "Where is the field you want to match?",
        items: sourceItems
    ) else { return nil }
    let source = sources[sourceIdx]

    let fields = context.fields(in: source)
    let fieldItems = fields.map(\.name)
    guard let fieldIdx = terminal.selectFromFilterableList(
        title: "Select field",
        items: fieldItems
    ) else { return nil }
    let selectedField = fields[fieldIdx]
    return (qualifiedName: selectedField.qualifiedName, displayName: selectedField.name)
}
```

- [ ] **Step 2: Add the buildFieldCompletions helper method**

In `RulesWizard.swift`, add after `selectField`:

```swift
/// Builds a sorted list of field names for autocomplete, combining catalog fields
/// and fields already used in existing rules.
private func buildFieldCompletions() -> [String] {
    var fieldSet = Set<String>()
    for source in context.availableSources() {
        for field in context.fields(in: source) {
            fieldSet.insert(field.name)
        }
    }
    for stageName in context.stageNames() {
        for slot in [RuleSlot.pre, .post] {
            for rule in context.rules(forStage: stageName, slot: slot) {
                for emit in rule.emit {
                    if let field = emit.field { fieldSet.insert(field) }
                }
                for write in rule.write {
                    if let field = write.field { fieldSet.insert(field) }
                }
            }
        }
    }
    return fieldSet.sorted()
}
```

- [ ] **Step 3: Refactor buildRule to use selectField**

Replace the source selection + field selection code in `buildRule` (lines ~297-319) with:

```swift
private func buildRule(editing existing: Rule? = nil) -> Rule? {
    if let existing {
        return editRuleMenu(existing: existing)
    }

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

    // Step 3: Actions (emit)
    let matchDesc = "\(selected.displayName) ~ \(pattern)"
    if !addActions(to: &builder, isWrite: false, matchContext: matchDesc) {
        return nil
    }

    // Step 4: Write actions
    if !addWriteActions(to: &builder, matchContext: matchDesc) {
        return nil
    }

    // Build
    switch builder.build() {
    case let .success(rule):
        return rule
    case let .failure(error):
        showError(error)
        return nil
    }
}
```

- [ ] **Step 4: Refactor promptForEmitConfig to use buildFieldCompletions**

Replace the field-set-building block at the top of `promptForEmitConfig` (lines ~394-418) with:

```swift
private func promptForEmitConfig(action: String) -> EmitConfig? {
    let uniqueFields = buildFieldCompletions()

    var field: String
```

Keep everything else in `promptForEmitConfig` unchanged (from `while true {` onward).

- [ ] **Step 5: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```
git add Sources/piqley/Wizard/RulesWizard.swift
git commit -m "refactor: extract selectField and buildFieldCompletions helpers"
```

---

### Task 4: Add `editAction` sub-menu method

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard.swift`

This is the action sub-menu that lets users edit individual parts of an EmitConfig (type, field, negated, values/replacements/source).

- [ ] **Step 1: Add the editAction method**

In `RulesWizard.swift`, add after the `buildFieldCompletions` method:

```swift
/// Shows a sub-menu for editing an individual emit/write action.
/// Returns the modified EmitConfig on Done, or nil on Esc (cancel).
private func editAction(_ config: EmitConfig) -> EmitConfig? {
    var action = config.action ?? "add"
    var field = config.field ?? ""
    var not = config.not
    var values = config.values ?? []
    var replacements = config.replacements ?? []
    var source = config.source ?? ""

    var cursor = 0

    while true {
        // Build tagged menu items
        enum Tag {
            case actionType, field, negated
            case value(Int), addValue
            case pattern(Int) // index into replacements
            case cloneSource
            case done
        }
        var menuItems: [(label: String, tag: Tag)] = []

        menuItems.append(("Type: \(action)", .actionType))
        menuItems.append(("Field: \(field)", .field))
        menuItems.append(("Negated: \(not == true ? "yes" : "no")", .negated))

        switch action {
        case "add", "remove":
            for (i, val) in values.enumerated() {
                menuItems.append(("Value: \(val)", .value(i)))
            }
            menuItems.append(("\(ANSI.dim)+ Add value\(ANSI.reset)", .addValue))

        case "replace":
            for (i, rep) in replacements.enumerated() {
                menuItems.append(("Pattern: \(rep.pattern) \u{2192} \(rep.replacement)", .pattern(i)))
            }
            menuItems.append(("\(ANSI.dim)+ Add replacement\(ANSI.reset)", .addValue))

        case "clone":
            menuItems.append(("Source: \(source)", .cloneSource))

        default:
            break
        }

        menuItems.append(("\(ANSI.bold)Done\(ANSI.reset)", .done))

        let items = menuItems.map(\.label)
        cursor = min(cursor, items.count - 1)

        terminal.drawScreen(
            title: "Edit action: \(action) \(field)",
            items: items,
            cursor: cursor,
            footer: "\u{2191}\u{2193} navigate  \u{23CE} edit  d delete value  Esc back"
        )

        let key = terminal.readKey()
        switch key {
        case .cursorUp: cursor = max(0, cursor - 1)
        case .cursorDown: cursor = min(items.count - 1, cursor + 1)
        case .enter:
            let tag = menuItems[cursor].tag
            switch tag {
            case .actionType:
                let actions = ["add", "remove", "replace", "removeField", "clone"]
                if let idx = terminal.selectFromList(
                    title: "Select action type",
                    items: actions
                ) {
                    let newAction = actions[idx]
                    if newAction != action {
                        action = newAction
                        // Clear action-specific state
                        values = []
                        replacements = []
                        source = ""
                        // Prompt for required fields immediately
                        switch newAction {
                        case "add", "remove":
                            if let val = terminal.promptForInput(
                                title: "Enter first value",
                                hint: "e.g. sony  or  regex:.*\\d+mm.*"
                            ) {
                                values.append(val)
                            }
                        case "replace":
                            if let pat = terminal.promptForInput(
                                title: "Replacement pattern",
                                hint: "Pattern to match in values"
                            ), let rep = terminal.promptForInput(
                                title: "Replacement string",
                                hint: "What to replace with (use $1, $2 for capture groups)"
                            ) {
                                replacements.append(Replacement(pattern: pat, replacement: rep))
                            }
                        case "clone":
                            if let src = terminal.promptForInput(
                                title: "Clone source",
                                hint: "source:field (e.g. original:IPTC:Keywords) or source name for wildcard"
                            ) {
                                source = src
                            }
                        default:
                            break
                        }
                    }
                }

            case .field:
                let completions = buildFieldCompletions()
                if let input = terminal.promptWithAutocomplete(
                    title: "Target field for \(action)",
                    hint: "The field to modify (e.g. keywords, IPTC:Keywords)",
                    completions: completions,
                    browsableList: completions,
                    defaultValue: field
                ) {
                    field = input
                }

            case .negated:
                not = (not == true) ? nil : true

            case .value(let i):
                if let newVal = terminal.promptForInput(
                    title: "Edit value",
                    hint: "Enter new value",
                    defaultValue: values[i]
                ) {
                    values[i] = newVal
                }

            case .addValue:
                if action == "replace" {
                    if let pat = terminal.promptForInput(
                        title: "Replacement pattern",
                        hint: "Pattern to match in values"
                    ), let repStr = terminal.promptForInput(
                        title: "Replacement string",
                        hint: "What to replace with (use $1, $2 for capture groups)"
                    ) {
                        replacements.append(Replacement(pattern: pat, replacement: repStr))
                    }
                } else {
                    if let val = terminal.promptForInput(
                        title: "Enter value",
                        hint: "e.g. sony  or  regex:.*\\d+mm.*"
                    ) {
                        values.append(val)
                    }
                }

            case .pattern(let i):
                let rep = replacements[i]
                if let pat = terminal.promptForInput(
                    title: "Replacement pattern",
                    hint: "Pattern to match in values",
                    defaultValue: rep.pattern
                ), let repStr = terminal.promptForInput(
                    title: "Replacement string",
                    hint: "What to replace with (use $1, $2 for capture groups)",
                    defaultValue: rep.replacement
                ) {
                    replacements[i] = Replacement(pattern: pat, replacement: repStr)
                }

            case .cloneSource:
                if let src = terminal.promptForInput(
                    title: "Clone source",
                    hint: "source:field (e.g. original:IPTC:Keywords) or source name for wildcard",
                    defaultValue: source
                ) {
                    source = src
                }

            case .done:
                // Build the EmitConfig and validate
                let built: EmitConfig
                switch action {
                case "add", "remove":
                    built = EmitConfig(action: action, field: field, values: values, replacements: nil, source: nil, not: not)
                case "replace":
                    built = EmitConfig(action: action, field: field, values: nil, replacements: replacements, source: nil, not: not)
                case "clone":
                    built = EmitConfig(action: action, field: field, values: nil, replacements: nil, source: source, not: not)
                case "removeField":
                    built = EmitConfig(action: action, field: field, values: nil, replacements: nil, source: nil, not: not)
                default:
                    built = EmitConfig(action: action, field: field, values: nil, replacements: nil, source: nil, not: not)
                }
                let result = context.validateEmit(built)
                if case let .failure(error) = result {
                    showError(error)
                    continue
                }
                return built
            }

        case .char("d"):
            let tag = menuItems[cursor].tag
            switch tag {
            case .value(let i):
                values.remove(at: i)
            case .pattern(let i):
                replacements.remove(at: i)
            default: break
            }

        case .escape:
            return nil

        default: break
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```
git add Sources/piqley/Wizard/RulesWizard.swift
git commit -m "feat: add editAction sub-menu for individual action editing"
```

---

### Task 5: Add `editRuleMenu` top-level method

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard.swift`

This is the top-level edit menu showing field, pattern, negated, all actions, and save.

- [ ] **Step 1: Add the editRuleMenu method**

In `RulesWizard.swift`, add after `editAction`, before `addActions`:

```swift
/// Shows a navigable menu for editing an existing rule's components individually.
/// Returns the modified Rule on Save, or nil on Esc (cancel).
private func editRuleMenu(existing: Rule) -> Rule? {
    var matchField = existing.match.field
    var matchPattern = existing.match.pattern
    var matchNot = existing.match.not
    var emitActions = existing.emit
    var writeActions = existing.write

    // Resolve display name for match field
    func fieldDisplayName() -> String {
        for source in context.availableSources() {
            for field in context.fields(in: source) {
                if field.qualifiedName == matchField {
                    return field.name
                }
            }
        }
        return matchField
    }

    var cursor = 0

    while true {
        // Build tagged menu items
        enum Tag {
            case matchField, matchPattern, matchNegated
            case emit(Int), addEmit
            case write(Int), addWrite
            case save
        }
        var menuItems: [(label: String, tag: Tag)] = []

        menuItems.append(("Field: \(fieldDisplayName())", .matchField))
        menuItems.append(("Pattern: \(matchPattern)", .matchPattern))
        menuItems.append(("Negated: \(matchNot == true ? "yes" : "no")", .matchNegated))

        for (i, emit) in emitActions.enumerated() {
            menuItems.append((formatEmitAction(emit), .emit(i)))
        }
        menuItems.append(("\(ANSI.dim)+ Add action\(ANSI.reset)", .addEmit))

        for (i, write) in writeActions.enumerated() {
            menuItems.append(("write: \(formatEmitAction(write))", .write(i)))
        }
        menuItems.append(("\(ANSI.dim)+ Add write action\(ANSI.reset)", .addWrite))

        menuItems.append(("\(ANSI.bold)Save\(ANSI.reset)", .save))

        let items = menuItems.map(\.label)
        cursor = min(cursor, items.count - 1)
        let matchDesc = "\(fieldDisplayName()) ~ \(matchPattern)"

        terminal.drawScreen(
            title: "Edit rule: \(matchDesc)",
            items: items,
            cursor: cursor,
            footer: "\u{2191}\u{2193} navigate  \u{23CE} edit  d delete  Esc cancel"
        )

        let key = terminal.readKey()
        switch key {
        case .cursorUp: cursor = max(0, cursor - 1)
        case .cursorDown: cursor = min(items.count - 1, cursor + 1)
        case .enter:
            let tag = menuItems[cursor].tag
            switch tag {
            case .matchField:
                if let selected = selectField() {
                    matchField = selected.qualifiedName
                }

            case .matchPattern:
                if let newPattern = terminal.promptForInput(
                    title: "Enter match pattern for \(fieldDisplayName())",
                    hint: "Plain text = exact match. Prefix with glob: or regex: for advanced.",
                    defaultValue: matchPattern
                ) {
                    matchPattern = newPattern
                }

            case .matchNegated:
                matchNot = (matchNot == true) ? nil : true

            case .emit(let i):
                if let edited = editAction(emitActions[i]) {
                    emitActions[i] = edited
                }

            case .addEmit:
                let actions = ["add", "remove", "replace", "removeField", "clone"]
                if let actionIdx = terminal.selectFromList(
                    title: "Select action type",
                    items: actions
                ) {
                    if let config = promptForEmitConfig(action: actions[actionIdx]) {
                        emitActions.append(config)
                    }
                }

            case .write(let i):
                if let edited = editAction(writeActions[i]) {
                    writeActions[i] = edited
                }

            case .addWrite:
                let actions = ["add", "remove", "replace", "removeField", "clone"]
                if let actionIdx = terminal.selectFromList(
                    title: "Select write action type",
                    items: actions
                ) {
                    if let config = promptForEmitConfig(action: actions[actionIdx]) {
                        writeActions.append(config)
                    }
                }

            case .save:
                var builder = RuleBuilder(context: context)
                let matchResult = builder.setMatch(field: matchField, pattern: matchPattern, not: matchNot)
                if case let .failure(error) = matchResult {
                    showError(error)
                    continue
                }
                var validationFailed = false
                for emit in emitActions {
                    if case let .failure(error) = builder.addEmit(emit) {
                        showError(error)
                        validationFailed = true
                        break
                    }
                }
                if validationFailed { continue }
                for write in writeActions {
                    if case let .failure(error) = builder.addWrite(write) {
                        showError(error)
                        validationFailed = true
                        break
                    }
                }
                if validationFailed { continue }
                switch builder.build() {
                case let .success(rule):
                    return rule
                case let .failure(error):
                    showError(error)
                    continue
                }
            }

        case .char("d"):
            let tag = menuItems[cursor].tag
            switch tag {
            case .emit(let i):
                emitActions.remove(at: i)
                cursor = min(cursor, menuItems.count - 2)
            case .write(let i):
                writeActions.remove(at: i)
                cursor = min(cursor, menuItems.count - 2)
            default: break
            }

        case .escape:
            return nil

        default: break
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```
git add Sources/piqley/Wizard/RulesWizard.swift
git commit -m "feat: add editRuleMenu for menu-based rule editing"
```

---

### Task 6: Manual smoke test

No automated tests exist for the TUI wizard (it requires interactive terminal input). Verify manually.

- [ ] **Step 1: Build the CLI**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 2: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`
Expected: All tests pass (including the new `setMatch(field:pattern:not:)` tests)

- [ ] **Step 3: Run CLI tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: All tests pass
