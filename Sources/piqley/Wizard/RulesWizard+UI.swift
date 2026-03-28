import Foundation
import PiqleyCore

extension RulesWizard {
    // MARK: - Slot Select

    func slotSelect(stageName: String) {
        var cursor = 0
        while true {
            let preCount = context.rules(forStage: stageName, slot: .pre).count
            let postCount = context.rules(forStage: stageName, slot: .post).count
            let items = [
                "Pre-rules (\(preCount) rules)  \(ANSI.dim)run before command\(ANSI.reset)",
                "Post-rules (\(postCount) rules)  \(ANSI.dim)run after command\(ANSI.reset)",
            ]

            terminal.drawScreen(
                title: "\(stageName)",
                items: items,
                cursor: cursor,
                footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  \u{23CE} select  s save  Esc back")
            )

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                let slot: RuleSlot = cursor == 0 ? .pre : .post
                slotRuleList(stageName: stageName, slot: slot)
            case .char("s"):
                save()
            case .escape:
                return
            default: break
            }
        }
    }

    // MARK: - Save / Quit

    /// Save current state to disk without exiting.
    func save() {
        applyDeletions()

        do {
            try StageFileManager.saveStages(context.stages, to: rulesDir)
            modified = false
            savedAt = Date()
            promptToAddToMissingStages()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    /// After saving, check if the plugin has rules for stages it's not in the pipeline for.
    /// Prompt the user to add it to those stages.
    private func promptToAddToMissingStages() {
        guard var workflow = try? WorkflowStore.load(name: workflowName) else { return }
        let pluginID = context.pluginIdentifier

        let missingStages = context.stages.filter { stageName, config in
            !config.isEffectivelyEmpty
                && !(workflow.pipeline[stageName]?.contains(pluginID) ?? false)
        }.map(\.key).sorted()

        for stage in missingStages {
            let prompt = "'\(pluginID)' has rules for '\(stage)' but is not in that stage's pipeline. Add it?"
            guard let choice = terminal.selectFromFilterableList(
                title: prompt,
                items: ["Yes", "No"]
            ) else { continue }

            if choice == 0 {
                var list = workflow.pipeline[stage] ?? []
                list.append(pluginID)
                workflow.pipeline[stage] = list
                do {
                    try WorkflowStore.save(workflow)
                } catch {
                    terminal.showMessage("Error updating workflow: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Exit the wizard cleanly, removing any empty stage files.
    func quit() {
        StageFileManager.cleanupEmptyStageFiles(stages: context.stages, pluginDir: rulesDir)
        terminal.restore()
        Foundation.exit(0)
    }

    /// Prompt to save if there are unsaved changes, then exit or return.
    /// Returns true if the user chose to stay (cancel), false if exiting.
    func promptUnsavedAndExit() {
        if !modified {
            quit()
        }

        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)You have unsaved changes.\(ANSI.reset)"
        buf += ANSI.moveTo(row: 3, col: 1)
        buf += "  s  Save and quit"
        buf += ANSI.moveTo(row: 4, col: 1)
        buf += "  d  Discard and quit"
        buf += ANSI.moveTo(row: 5, col: 1)
        buf += "  Esc  Cancel (go back)"
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)s save  d discard  Esc cancel\(ANSI.reset)"
        terminal.write(buf)

        while true {
            let key = terminal.readKey()
            switch key {
            case .char("s"):
                save()
                quit()
            case .char("d"):
                quit()
            case .escape:
                return
            default: break
            }
        }
    }

    /// Show an error message, wait for keypress.
    func showError(_ error: RuleValidationError) {
        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.red)\(ANSI.bold)Error: \(error.errorDescription ?? "Unknown error")\(ANSI.reset)"
        if let suggestion = error.recoverySuggestion {
            buf += ANSI.moveTo(row: 3, col: 1)
            buf += "\(ANSI.dim)\(suggestion)\(ANSI.reset)"
        }
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)Press any key to continue\(ANSI.reset)"
        terminal.write(buf)
        _ = terminal.readKey()
    }

    /// Remove all rules marked for deletion from the context.
    /// Processes in reverse index order so removals don't shift indices.
    func applyDeletions() {
        var byStageSlot: [String: [(slot: RuleSlot, index: Int)]] = [:]
        for key in deletedRules {
            let parts = key.split(separator: ":")
            guard parts.count == 3,
                  let slot = parts[1] == "pre" ? RuleSlot.pre : (parts[1] == "post" ? .post : nil),
                  let index = Int(parts[2])
            else { continue }
            let stageName = String(parts[0])
            byStageSlot[stageName, default: []].append((slot: slot, index: index))
        }

        for (stageName, entries) in byStageSlot {
            let sorted = entries.sorted { $0.index > $1.index }
            if var stage = context.stages[stageName] {
                for entry in sorted {
                    try? stage.removeRule(at: entry.index, slot: entry.slot)
                }
                context.stages[stageName] = stage
            }
        }
        deletedRules.removeAll()
    }

    // MARK: - Action Verb Helpers

    /// Returns a verb phrase that describes what an action does to a field,
    /// for use in hint text like "The field to <verb>".
    func actionFieldVerb(_ action: String) -> String {
        switch action {
        case "add": "add to"
        case "remove": "remove from"
        case "replace": "replace values in"
        case "removeField": "remove"
        case "clone": "clone into"
        default: action
        }
    }

    // MARK: - Formatting

    func formatRule(_ rule: Rule, index: Int) -> String {
        let matchDesc = if let match = rule.match {
            "\(match.field) ~ \(match.pattern)"
        } else {
            "(always)"
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
        return "\(index + 1). \(matchDesc) \u{2192} \(emitSummary)\(writeSummary)"
    }

    /// Formats a single emit/write action for display in the edit menu.
    func formatEmitAction(_ emit: EmitConfig) -> String {
        let action = emit.action ?? "add"
        let target = emit.field ?? "keywords"
        switch action {
        case "add", "remove":
            let vals = emit.values?.joined(separator: ", ") ?? ""
            return "\(actionFieldVerb(action)) \(target)=[\(vals)]"
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

    // MARK: - Formatting Helpers

    /// Apply a Unicode strikethrough to each character.
    func strikethrough(_ text: String) -> String {
        var result = ""
        for char in text {
            result.append(char)
            result.append("\u{0336}")
        }
        return result
    }

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
            var row = 3
            if let match = rule.match {
                let displayName = resolveFieldDisplayName(match.field)
                buf += "\(ANSI.bold)Rule \(index + 1): \(displayName) ~ \(match.pattern)\(ANSI.reset)"

                // Match section
                buf += ANSI.moveTo(row: row, col: 1)
                buf += "\(ANSI.dim)\u{2500}\u{2500} Match \(String(repeating: "\u{2500}", count: max(0, size.cols - 9)))\(ANSI.reset)"
                row += 1

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

                // Match section
                buf += ANSI.moveTo(row: row, col: 1)
                buf += "\(ANSI.dim)\u{2500}\u{2500} Match \(String(repeating: "\u{2500}", count: max(0, size.cols - 9)))\(ANSI.reset)"
                row += 1

                buf += ANSI.moveTo(row: row, col: 1)
                buf += "  (always applies)"
                row += 2
            }

            // Emit Actions section
            buf += ANSI.moveTo(row: row, col: 1)
            let emitCount = rule.emit.count
            let emitFill = String(repeating: "\u{2500}", count: max(0, size.cols - 20 - String(emitCount).count))
            buf += "\(ANSI.dim)\u{2500}\u{2500} Emit Actions (\(emitCount)) \(emitFill)\(ANSI.reset)"
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
            let writeFill = String(repeating: "\u{2500}", count: max(0, size.cols - 21 - String(writeCount).count))
            buf += "\(ANSI.dim)\u{2500}\u{2500} Write Actions (\(writeCount)) \(writeFill)\(ANSI.reset)"
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
}
