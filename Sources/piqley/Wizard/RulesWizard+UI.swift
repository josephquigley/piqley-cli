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

        // Check for non-dependency namespace references
        let referenced = Self.extractReferencedNamespaces(from: context.stages)
        let nonDeps = Self.nonDependencyNamespaces(referenced, dependencies: dependencyIdentifiers)
        if !nonDeps.isEmpty {
            let names = nonDeps.sorted().joined(separator: ", ")
            if !terminal.confirm(
                "Rules reference plugins that are not declared dependencies: \(names). Save anyway?"
            ) {
                return
            }
        }

        do {
            try StageFileManager.saveStages(context.stages, to: pluginDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    /// Exit the wizard cleanly, removing any empty stage files.
    func quit() {
        StageFileManager.cleanupEmptyStageFiles(stages: context.stages, pluginDir: pluginDir)
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

    // MARK: - Formatting

    func formatRule(_ rule: Rule, index: Int) -> String {
        let field = rule.match.field
        let pattern = rule.match.pattern
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
        return "\(index + 1). \(field) ~ \(pattern) \u{2192} \(emitSummary)\(writeSummary)"
    }

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
}
