import Foundation
import PiqleyCore

extension RulesWizard {
    // MARK: - Generic UI Components

    /// Show a selectable list and return the chosen index, or nil if cancelled.
    func selectFromList(title: String, items: [String]) -> Int? {
        var cursor = 0
        while true {
            drawScreen(
                title: title,
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} select  Esc cancel"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .pageUp: cursor = max(0, cursor - 10)
            case .pageDown: cursor = min(items.count - 1, cursor + 10)
            case .enter: return cursor
            case .escape, .ctrlC: return nil
            default: break
            }
        }
    }

    /// Prompt for text input. Returns nil if cancelled.
    func promptForInput(title: String, hint: String, defaultValue: String? = nil) -> String? {
        var input = defaultValue ?? ""
        let size = ANSI.terminalSize()

        while true {
            var buf = ""
            buf += ANSI.clearScreen()
            buf += ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(title)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 2, col: 1)
            buf += "\(ANSI.dim)\(hint)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 4, col: 1)
            buf += "\u{25B8} \(input)\u{2588}"
            buf += ANSI.moveTo(row: size.rows, col: 1)
            buf += "\(ANSI.dim)Enter to confirm  Esc to cancel\(ANSI.reset)"
            terminal.write(buf)

            let key = terminal.readKey()
            switch key {
            case let .char(char):
                input.append(char)
            case .backspace:
                if !input.isEmpty { input.removeLast() }
            case .enter:
                if !input.isEmpty { return input }
            case .escape, .ctrlC:
                return nil
            default: break
            }
        }
    }

    /// Prompt for text input with autocomplete suggestions.
    /// Tab completes the top match. If `browsableList` is provided, `l` opens
    /// a selectable list to pick from. Returns nil if cancelled.
    func promptWithAutocomplete(
        title: String, hint: String, completions: [String],
        browsableList: [String]? = nil, defaultValue: String? = nil
    ) -> String? {
        var input = defaultValue ?? ""
        let size = ANSI.terminalSize()
        let maxSuggestions = 5
        let hasList = browsableList != nil

        while true {
            let query = input.lowercased()
            let matches = query.isEmpty ? [] : completions.filter {
                $0.lowercased().contains(query)
            }

            var buf = ""
            buf += ANSI.clearScreen()
            buf += ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(title)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 2, col: 1)
            buf += "\(ANSI.dim)\(hint)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 4, col: 1)
            buf += "\u{25B8} \(input)\u{2588}"

            // Show suggestions
            for (idx, match) in matches.prefix(maxSuggestions).enumerated() {
                buf += ANSI.moveTo(row: 6 + idx, col: 3)
                if idx == 0 {
                    buf += "\(ANSI.dim)Tab \u{2192} \(ANSI.reset)\(match)"
                } else {
                    buf += "\(ANSI.dim)  \(match)\(ANSI.reset)"
                }
            }
            if matches.count > maxSuggestions {
                buf += ANSI.moveTo(row: 6 + maxSuggestions, col: 3)
                buf += "\(ANSI.dim)  ... \(matches.count - maxSuggestions) more\(ANSI.reset)"
            }

            buf += ANSI.moveTo(row: size.rows, col: 1)
            let listHint = hasList ? "  Ctrl+L browse list" : ""
            buf += "\(ANSI.dim)Tab autocomplete\(listHint)  Enter confirm  Esc cancel\(ANSI.reset)"
            terminal.write(buf)

            let key = terminal.readKey()
            switch key {
            case .ctrlL where hasList:
                if let list = browsableList,
                   let idx = selectFromList(title: "Select field", items: list)
                {
                    input = list[idx]
                }
            case let .char(char):
                input.append(char)
            case .backspace:
                if !input.isEmpty { input.removeLast() }
            case .tab:
                if let first = matches.first {
                    input = first
                }
            case .enter:
                if !input.isEmpty { return input }
            case .escape, .ctrlC:
                return nil
            default: break
            }
        }
    }

    /// Show a y/n confirmation. Returns true for yes.
    func confirm(_ message: String) -> Bool {
        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)\(message)\(ANSI.reset)"
        buf += ANSI.moveTo(row: 3, col: 1)
        buf += "y/n \u{25B8} "
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)y yes  n no\(ANSI.reset)"
        terminal.write(buf)

        while true {
            let key = terminal.readKey()
            switch key {
            case .char("y"), .char("Y"): return true
            case .char("n"), .char("N"), .escape: return false
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

    // MARK: - Drawing

    func drawScreen(title: String, items: [String], cursor: Int, footer: String) {
        let size = ANSI.terminalSize()
        let titleLines = title.split(separator: "\n", omittingEmptySubsequences: false)
        let titleHeight = titleLines.count
        let itemStartRow = titleHeight + 2
        let maxVisible = size.rows - titleHeight - 3
        let scrollOffset = max(0, cursor - maxVisible + 1)

        var buf = ""
        buf += ANSI.clearScreen()
        for (idx, line) in titleLines.enumerated() {
            buf += ANSI.moveTo(row: idx + 1, col: 1)
            if idx == titleLines.count - 1 {
                buf += "\(ANSI.bold)\(line)\(ANSI.reset)"
            } else {
                buf += "\(line)"
            }
        }

        let visible = Array(items.enumerated()).dropFirst(scrollOffset).prefix(maxVisible)
        for (row, entry) in visible.enumerated() {
            let (idx, text) = entry
            buf += ANSI.moveTo(row: row + itemStartRow, col: 1)
            if idx == cursor {
                buf += "\(ANSI.inverse) \u{25B8} \(text) \(ANSI.reset)"
            } else {
                buf += "   \(text)"
            }
        }

        if items.count > maxVisible {
            buf += ANSI.moveTo(row: itemStartRow - 1, col: size.cols - 10)
            buf += "\(ANSI.dim)\(scrollOffset + 1)-\(min(scrollOffset + maxVisible, items.count)) of \(items.count)\(ANSI.reset)"
        }

        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)\(footer)\(ANSI.reset)"

        terminal.write(buf)
    }

    // MARK: - Save / Quit

    /// Save current state to disk without exiting.
    func save() {
        applyDeletions()
        do {
            try RulesWizard.saveStages(context.stages, to: pluginDir)
            modified = false
        } catch {
            showMessage("Error saving: \(error.localizedDescription)")
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

    /// Show a brief message, wait for keypress.
    func showMessage(_ message: String) {
        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)\(message)\(ANSI.reset)"
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
            let target = emit.field
            if let values = emit.values {
                return "\(action) \(target)=[\(values.joined(separator: ", "))]"
            } else if emit.replacements != nil {
                return "replace \(target)"
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
