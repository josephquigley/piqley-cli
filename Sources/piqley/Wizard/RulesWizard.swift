import Foundation
import PiqleyCore

/// ANSI-based interactive rule editor wizard.
/// Uses raw terminal mode with cursor-positioned selection lists.
final class RulesWizard {
    var context: RuleEditingContext
    let pluginDir: URL
    let terminal: RawTerminal
    var modified = false

    init(context: RuleEditingContext, pluginDir: URL) {
        self.context = context
        self.pluginDir = pluginDir
        terminal = RawTerminal()
    }

    func run() throws {
        defer { terminal.restore() }
        stageSelect()
    }

    // MARK: - Stage Select

    private func stageSelect() {
        let stageNames = context.stageNames()
        guard !stageNames.isEmpty else {
            terminal.restore()
            print("No stages found for plugin '\(context.pluginIdentifier)'.")
            return
        }

        var cursor = 0
        while true {
            let items = stageNames.map { name in
                let count = context.rules(forStage: name, slot: .pre).count
                    + context.rules(forStage: name, slot: .post).count
                let hasBinary = context.stageHasBinary(name)
                if hasBinary {
                    let pre = context.rules(forStage: name, slot: .pre).count
                    let post = context.rules(forStage: name, slot: .post).count
                    return "\(name) (\(count) rules: \(pre) pre, \(post) post)"
                }
                return "\(name) (\(count) rules)"
            }

            drawScreen(
                title: "Edit Rules: \(context.pluginIdentifier)",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} select  s save & quit  q quit"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                ruleList(stageName: stageNames[cursor])
            case .char("s"):
                saveAndQuit()
            case .char("q"), .escape, .ctrlC:
                quit()
            default: break
            }
        }
    }

    // MARK: - Rule List

    private func ruleList(stageName: String) {
        let slot: RuleSlot = .pre
        var cursor = 0

        while true {
            let rules = context.rules(forStage: stageName, slot: slot)
            let items: [String] = rules.isEmpty
                ? ["(no rules)"]
                : rules.enumerated().map { idx, rule in formatRule(rule, index: idx) }

            drawScreen(
                title: "\(stageName) rules",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  a add  e edit  d delete  r reorder  q back"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .pageUp: cursor = max(0, cursor - 10)
            case .pageDown: cursor = min(items.count - 1, cursor + 10)
            case .enter, .char("e"):
                if !rules.isEmpty, cursor < rules.count {
                    editRule(stageName: stageName, slot: slot, index: cursor)
                }
            case .char("a"):
                addRule(stageName: stageName, slot: slot)
            case .char("d"):
                if !rules.isEmpty, cursor < rules.count {
                    deleteRule(stageName: stageName, slot: slot, index: cursor)
                    cursor = min(cursor, max(0, rules.count - 2))
                }
            case .char("r"):
                if !rules.isEmpty, cursor < rules.count, cursor > 0 {
                    if var stage = context.stages[stageName] {
                        try? stage.moveRule(from: cursor, to: cursor - 1, slot: slot)
                        context.stages[stageName] = stage
                        modified = true
                        cursor -= 1
                    }
                }
            case .char("q"), .escape:
                return
            default: break
            }
        }
    }

    // MARK: - Add Rule

    private func addRule(stageName: String, slot: RuleSlot) {
        guard let rule = buildRule() else { return }
        if var stage = context.stages[stageName] {
            try? stage.appendRule(rule, slot: slot)
            context.stages[stageName] = stage
            modified = true
        }
    }

    // MARK: - Edit Rule

    private func editRule(stageName: String, slot: RuleSlot, index: Int) {
        let existing = context.rules(forStage: stageName, slot: slot)[index]
        guard let rule = buildRule(editing: existing) else { return }
        if var stage = context.stages[stageName] {
            try? stage.replaceRule(at: index, with: rule, slot: slot)
            context.stages[stageName] = stage
            modified = true
        }
    }

    // MARK: - Delete Rule

    private func deleteRule(stageName: String, slot: RuleSlot, index: Int) {
        let rules = context.rules(forStage: stageName, slot: slot)
        guard index < rules.count else { return }

        let desc = formatRule(rules[index], index: index)
        if confirm("Delete: \(desc)?") {
            if var stage = context.stages[stageName] {
                try? stage.removeRule(at: index, slot: slot)
                context.stages[stageName] = stage
                modified = true
            }
        }
    }

    // MARK: - Build Rule (wizard flow)

    private func buildRule(editing existing: Rule? = nil) -> Rule? {
        var builder = RuleBuilder(context: context)

        // Pre-populate if editing
        if let existing {
            _ = builder.setMatch(field: existing.match.field, pattern: existing.match.pattern)
            for emit in existing.emit {
                _ = builder.addEmit(emit)
            }
            for write in existing.write {
                _ = builder.addWrite(write)
            }
        }

        // Step 1: Select source
        let sources = context.availableSources()
        guard let sourceIdx = selectFromList(
            title: "Select source to match",
            items: sources
        ) else { return nil }
        let source = sources[sourceIdx]

        // Step 2: Select field
        let fields = context.fields(in: source)
        let fieldItems = fields.map { "\($0.qualifiedName)" }
        guard let fieldIdx = selectFromList(
            title: "Select field from \(source)",
            items: fieldItems
        ) else { return nil }
        let selectedField = fields[fieldIdx]

        // Step 3: Enter pattern
        guard let pattern = promptForInput(
            title: "Enter match pattern",
            hint: "Plain text = exact match. Prefix with glob: or regex: for advanced.",
            defaultValue: existing?.match.pattern
        ) else { return nil }

        let matchResult = builder.setMatch(
            field: selectedField.qualifiedName,
            pattern: pattern
        )
        if case let .failure(error) = matchResult {
            showError(error)
            return nil
        }

        // Step 4: Emit actions
        // Reset emit actions if we pre-populated (we're rebuilding)
        if existing != nil {
            builder.reset()
            _ = builder.setMatch(field: selectedField.qualifiedName, pattern: pattern)
        }

        if !addEmitActions(to: &builder, title: "Emit actions (modify plugin output)") {
            return nil
        }

        // Step 5: Write actions
        if !addWriteActions(to: &builder, title: "Write actions (modify file metadata)") {
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

    private func addEmitActions(to builder: inout RuleBuilder, title: String) -> Bool {
        let actions = ["add", "remove", "replace", "removeField", "clone"]

        while true {
            guard let actionIdx = selectFromList(
                title: title,
                items: actions + ["(done - no more emit actions)"]
            ) else { return false }

            if actionIdx == actions.count { break } // done
            let action = actions[actionIdx]

            guard let config = promptForEmitConfig(action: action) else { return false }
            let result = builder.addEmit(config)
            if case let .failure(error) = result {
                showError(error)
                continue
            }

            if !confirm("Add another emit action?") { break }
        }
        return true
    }

    private func addWriteActions(to builder: inout RuleBuilder, title: String) -> Bool {
        if !confirm("Add write actions?") { return true }

        let actions = ["add", "remove", "replace", "removeField", "clone"]

        while true {
            guard let actionIdx = selectFromList(
                title: title,
                items: actions + ["(done - no more write actions)"]
            ) else { return false }

            if actionIdx == actions.count { break }
            let action = actions[actionIdx]

            guard let config = promptForEmitConfig(action: action) else { return false }
            let result = builder.addWrite(config)
            if case let .failure(error) = result {
                showError(error)
                continue
            }

            if !confirm("Add another write action?") { break }
        }
        return true
    }

    private func promptForEmitConfig(action: String) -> EmitConfig? {
        guard let field = promptForInput(
            title: "Target field for \(action)",
            hint: "The field to modify (e.g. keywords, IPTC:Keywords)"
        ) else { return nil }

        switch action {
        case "add", "remove":
            guard let valuesStr = promptForInput(
                title: "Values (comma-separated)",
                hint: "e.g. sony, mirrorless, alpha"
            ) else { return nil }
            let values = valuesStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return EmitConfig(action: action, field: field, values: values, replacements: nil, source: nil)

        case "replace":
            guard let pattern = promptForInput(
                title: "Replacement pattern",
                hint: "Pattern to match in values"
            ) else { return nil }
            guard let replacement = promptForInput(
                title: "Replacement string",
                hint: "What to replace with (use $1, $2 for capture groups)"
            ) else { return nil }
            return EmitConfig(
                action: action, field: field, values: nil,
                replacements: [Replacement(pattern: pattern, replacement: replacement)],
                source: nil
            )

        case "removeField":
            return EmitConfig(action: action, field: field, values: nil, replacements: nil, source: nil)

        case "clone":
            guard let source = promptForInput(
                title: "Clone source",
                hint: "source:field (e.g. original:IPTC:Keywords) or source name for wildcard"
            ) else { return nil }
            return EmitConfig(action: action, field: field, values: nil, replacements: nil, source: source)

        default:
            return nil
        }
    }
}
