# Rule Inspect Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an inspect (i) command to the TUI rules editor that shows a read-only sectioned detail view of a rule, with the option to press 'e' to enter edit mode.

**Architecture:** New `inspectRule` method in `RulesWizard+UI.swift` renders a full-screen ANSI detail view with Match, Emit Actions, and Write Actions sections. The `slotRuleList` method in `RulesWizard.swift` gets a new 'i' keybinding that calls it.

**Tech Stack:** Swift, raw ANSI terminal rendering (RawTerminal, ANSI helpers)

**Spec:** `docs/superpowers/specs/2026-03-25-rule-inspect-command-design.md`

---

### Task 1: Add `inspectRule` method to RulesWizard+UI.swift

**Files:**
- Modify: `Sources/piqley/Wizard/RulesWizard+UI.swift`

This task adds the inspect view rendering and interaction loop.

- [ ] **Step 1: Add the `inspectRule` method**

Add this method to the `RulesWizard` extension in `RulesWizard+UI.swift`, after the `formatEmitAction` method (before the closing `}`):

```swift
// MARK: - Inspect Rule

/// Displays a read-only sectioned detail view of a rule.
/// Press 'e' to edit, Esc to return to the rule list.
func inspectRule(stageName: String, slot: RuleSlot, index: Int) {
    while true {
        let rules = context.rules(forStage: stageName, slot: slot)
        guard index < rules.count else { return }
        let rule = rules[index]

        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)

        // Title
        let displayName = resolveFieldDisplayName(rule.match.field)
        buf += "\(ANSI.bold)Rule \(index + 1): \(displayName) ~ \(rule.match.pattern)\(ANSI.reset)"

        // Match section
        var row = 3
        buf += ANSI.moveTo(row: row, col: 1)
        buf += "\(ANSI.dim)\u{2500}\u{2500} Match \(String(repeating: "\u{2500}", count: max(0, size.cols - 9)))\(ANSI.reset)"
        row += 1

        buf += ANSI.moveTo(row: row, col: 1)
        let fieldDisplay: String
        if displayName == rule.match.field {
            fieldDisplay = displayName
        } else {
            fieldDisplay = "\(displayName)  \(ANSI.dim)(\(rule.match.field))\(ANSI.reset)"
        }
        buf += "  Field:    \(fieldDisplay)"
        row += 1

        buf += ANSI.moveTo(row: row, col: 1)
        buf += "  Pattern:  \(rule.match.pattern)"
        row += 1

        buf += ANSI.moveTo(row: row, col: 1)
        buf += "  Negated:  \(rule.match.not == true ? "yes" : "no")"
        row += 2

        // Emit Actions section
        buf += ANSI.moveTo(row: row, col: 1)
        let emitCount = rule.emit.count
        buf += "\(ANSI.dim)\u{2500}\u{2500} Emit Actions (\(emitCount)) \(String(repeating: "\u{2500}", count: max(0, size.cols - 20 - String(emitCount).count)))\(ANSI.reset)"
        row += 1

        if rule.emit.isEmpty {
            buf += ANSI.moveTo(row: row, col: 1)
            buf += "  \(ANSI.dim)(none)\(ANSI.reset)"
            row += 1
        } else {
            for (idx, emit) in rule.emit.enumerated() {
                buf += ANSI.moveTo(row: row, col: 1)
                let negatedSuffix = emit.not == true ? " \(ANSI.dim)(negated)\(ANSI.reset)" : ""
                buf += "  \(idx + 1). \(formatEmitAction(emit))\(negatedSuffix)"
                row += 1
            }
        }
        row += 1

        // Write Actions section
        buf += ANSI.moveTo(row: row, col: 1)
        let writeCount = rule.write.count
        buf += "\(ANSI.dim)\u{2500}\u{2500} Write Actions (\(writeCount)) \(String(repeating: "\u{2500}", count: max(0, size.cols - 21 - String(writeCount).count)))\(ANSI.reset)"
        row += 1

        if rule.write.isEmpty {
            buf += ANSI.moveTo(row: row, col: 1)
            buf += "  \(ANSI.dim)(none)\(ANSI.reset)"
        } else {
            for (idx, write) in rule.write.enumerated() {
                buf += ANSI.moveTo(row: row, col: 1)
                let negatedSuffix = write.not == true ? " \(ANSI.dim)(negated)\(ANSI.reset)" : ""
                buf += "  \(idx + 1). \(formatEmitAction(write))\(negatedSuffix)"
                row += 1
            }
        }

        // Footer
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)e edit  Esc back\(ANSI.reset)"
        terminal.write(buf)

        let key = terminal.readKey()
        switch key {
        case .char("e"):
            let delKey = deletionKey(stage: stageName, slot: slot, index: index)
            if !deletedRules.contains(delKey) {
                let existing = rules[index]
                if let edited = editRuleMenu(existing: existing) {
                    if var stage = context.stages[stageName] {
                        try? stage.replaceRule(at: index, with: edited, slot: slot)
                        context.stages[stageName] = stage
                        modified = true
                    }
                }
            }
            // Loop continues: redraws inspect with updated rule
        case .escape:
            return
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: "Build complete!" with no errors

- [ ] **Step 3: Commit**

Commit message: `feat: add inspectRule detail view to rules editor`

---

### Task 2: Wire up 'i' keybinding in slotRuleList

**Files:**
- Modify: `Sources/piqley/Wizard/RulesWizard.swift:155-225`

This task adds the 'i' key handler and updates the footer hint.

- [ ] **Step 1: Update the footer string**

In `slotRuleList` (around line 180), change the footer string from:

```swift
footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  a add  e edit  \(deleteLabel)  r reorder  s save  Esc back")
```

to:

```swift
footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  a add  e edit  i inspect  \(deleteLabel)  r reorder  s save  Esc back")
```

- [ ] **Step 2: Add the 'i' key case**

In `slotRuleList`, add a new case after the `.char("a")` case (around line 198). Insert before the `.char("d")` case:

```swift
case .char("i"):
    if !rules.isEmpty, cursor < rules.count {
        let delKey = deletionKey(stage: stageName, slot: slot, index: cursor)
        if !deletedRules.contains(delKey) {
            inspectRule(stageName: stageName, slot: slot, index: cursor)
        }
    }
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: "Build complete!" with no errors

- [ ] **Step 4: Commit**

Commit message: `feat: wire up inspect (i) keybinding in rule list`

---

### Task 3: Manual verification

- [ ] **Step 1: Run the rules editor against a plugin with existing rules**

Run: `swift run piqley plugin rules`

Select a workflow and plugin that has rules configured. Navigate to a rule list.

- [ ] **Step 2: Verify the footer shows the new 'i inspect' hint**

The footer should read: `... a add  e edit  i inspect  d delete  r reorder  s save  Esc back`

- [ ] **Step 3: Press 'i' on a rule and verify the inspect view**

Confirm:
- Title shows `Rule N: fieldName ~ pattern`
- Match section shows field (with qualified name in parens if different), pattern, negated
- Emit Actions section lists each action numbered
- Write Actions section lists each action numbered (or "(none)")
- Footer shows `e edit  Esc back`

- [ ] **Step 4: Press 'e' from inspect view, edit a value, save, and confirm inspect redraws**

After saving an edit, the inspect view should redraw showing the updated values.

- [ ] **Step 5: Press Esc to return to rule list**

Confirm cursor position is preserved.
