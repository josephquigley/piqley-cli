import Foundation
import PiqleyCore

extension RulesWizard {
    // MARK: - Save / Quit

    /// Save current state to disk without exiting.
    func save() {
        applyDeletions()
        do {
            try RulesWizard.saveStages(context.stages, to: pluginDir)
            modified = false
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    /// Exit the wizard cleanly.
    func quit() {
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

    // MARK: - File I/O

    static func saveStages(_ stages: [String: StageConfig], to pluginDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (hookName, stageConfig) in stages {
            let data = try encoder.encode(stageConfig)
            let stageFile = pluginDir
                .appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")
            try data.write(to: stageFile, options: .atomic)
        }
    }
}
