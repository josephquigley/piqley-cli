import Foundation
import PiqleyCore

/// ANSI-based interactive rule editor wizard.
/// Uses raw terminal mode with cursor-positioned selection lists.
final class RulesWizard {
    var context: RuleEditingContext
    let pluginDir: URL
    let terminal: RawTerminal
    var modified = false

    /// Tracks which rules are marked for deletion (by stage + slot + index).
    /// Deleted rules are shown struck-through and removed on save.
    var deletedRules: Set<String> = []

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

            terminal.drawScreen(
                title: "Edit Rules: \(context.pluginIdentifier)",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} select  s save  Esc quit"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                ruleList(stageName: stageNames[cursor])
            case .char("s"):
                save()
            case .escape, .ctrlC:
                promptUnsavedAndExit()
            default: break
            }
        }
    }

    // MARK: - Rule List

    private func deletionKey(stage: String, slot: RuleSlot, index: Int) -> String {
        "\(stage):\(slot):\(index)"
    }

    private func ruleList(stageName: String) {
        let slot: RuleSlot = .pre
        var cursor = 0

        while true {
            let rules = context.rules(forStage: stageName, slot: slot)
            let items: [String] = rules.isEmpty
                ? ["(no rules)"]
                : rules.enumerated().map { idx, rule in
                    let key = deletionKey(stage: stageName, slot: slot, index: idx)
                    let text = formatRule(rule, index: idx)
                    if deletedRules.contains(key) {
                        return "\(ANSI.dim)\u{0336}" + strikethrough(text) + "\(ANSI.reset)"
                    }
                    return text
                }

            // Show "undelete" in footer if current rule is marked for deletion
            let isCurrentDeleted = !rules.isEmpty && cursor < rules.count
                && deletedRules.contains(deletionKey(stage: stageName, slot: slot, index: cursor))
            let deleteLabel = isCurrentDeleted ? "d undelete" : "d delete"

            terminal.drawScreen(
                title: "\(stageName) rules",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  a add  e edit  \(deleteLabel)  r reorder  s save  Esc back"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .pageUp: cursor = max(0, cursor - 10)
            case .pageDown: cursor = min(items.count - 1, cursor + 10)
            case .enter, .char("e"):
                if !rules.isEmpty, cursor < rules.count {
                    let delKey = deletionKey(stage: stageName, slot: slot, index: cursor)
                    if !deletedRules.contains(delKey) {
                        editRule(stageName: stageName, slot: slot, index: cursor)
                    }
                }
            case .char("a"):
                addRule(stageName: stageName, slot: slot)
            case .char("d"):
                if !rules.isEmpty, cursor < rules.count {
                    let delKey = deletionKey(stage: stageName, slot: slot, index: cursor)
                    if deletedRules.contains(delKey) {
                        // Undelete — toggle
                        deletedRules.remove(delKey)
                    } else {
                        deletedRules.insert(delKey)
                        modified = true
                    }
                }
            case .char("r"):
                if !rules.isEmpty, cursor < rules.count, rules.count > 1 {
                    if let newPos = interactiveReorder(
                        stageName: stageName, slot: slot, startIndex: cursor
                    ) {
                        cursor = newPos
                    }
                }
            case .char("s"):
                save()
            case .escape:
                return
            default: break
            }
        }
    }

    /// Apply a Unicode strikethrough to each character.
    private func strikethrough(_ text: String) -> String {
        var result = ""
        for char in text {
            result.append(char)
            result.append("\u{0336}")
        }
        return result
    }

    // MARK: - Interactive Reorder

    /// Enter reorder mode: the selected rule is shown indented and italic,
    /// up/down arrows move it. Enter confirms, Escape cancels.
    /// Returns the new index on confirm, or nil on cancel.
    private func interactiveReorder(
        stageName: String, slot: RuleSlot, startIndex: Int
    ) -> Int? {
        var position = startIndex
        let originalRules = context.rules(forStage: stageName, slot: slot)
        // Work on a mutable copy of the stage so we can preview moves
        guard var stage = context.stages[stageName] else { return nil }
        let ruleCount = originalRules.count

        while true {
            let rules = context.rules(forStage: stageName, slot: slot)
            let items: [String] = rules.enumerated().map { idx, rule in
                let key = deletionKey(stage: stageName, slot: slot, index: idx)
                let text = formatRule(rule, index: idx)
                if idx == position {
                    // The rule being moved: indented + italic
                    return "  \(ANSI.italic)\(text)\(ANSI.reset)"
                }
                if deletedRules.contains(key) {
                    return "\(ANSI.dim)" + strikethrough(text) + "\(ANSI.reset)"
                }
                return text
            }

            terminal.drawScreen(
                title: "\(stageName) rules — reordering",
                items: items,
                cursor: position,
                footer: "\u{2191}\u{2193} move  \u{23CE} confirm  Esc cancel"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp:
                if position > 0 {
                    try? stage.moveRule(from: position, to: position - 1, slot: slot)
                    context.stages[stageName] = stage
                    // Swap deletion keys
                    swapDeletionKeys(stage: stageName, slot: slot, indexA: position, indexB: position - 1)
                    position -= 1
                }
            case .cursorDown:
                if position < ruleCount - 1 {
                    try? stage.moveRule(from: position, to: position + 1, slot: slot)
                    context.stages[stageName] = stage
                    swapDeletionKeys(stage: stageName, slot: slot, indexA: position, indexB: position + 1)
                    position += 1
                }
            case .enter:
                if position != startIndex {
                    modified = true
                }
                return position
            case .escape:
                // Cancel — restore original order
                context.stages[stageName] = StageConfig(
                    preRules: slot == .pre ? originalRules : context.stages[stageName]?.preRules,
                    binary: context.stages[stageName]?.binary,
                    postRules: slot == .post ? originalRules : context.stages[stageName]?.postRules
                )
                return nil
            default: break
            }
        }
    }

    private func swapDeletionKeys(stage: String, slot: RuleSlot, indexA: Int, indexB: Int) {
        let keyA = deletionKey(stage: stage, slot: slot, index: indexA)
        let keyB = deletionKey(stage: stage, slot: slot, index: indexB)
        let aDeleted = deletedRules.contains(keyA)
        let bDeleted = deletedRules.contains(keyB)
        deletedRules.remove(keyA)
        deletedRules.remove(keyB)
        if aDeleted { deletedRules.insert(keyB) }
        if bDeleted { deletedRules.insert(keyA) }
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

    // MARK: - Build Rule (wizard flow)

    private func buildRule(editing existing: Rule? = nil) -> Rule? {
        var builder = RuleBuilder(context: context)

        // Step 1: Select source — explain what this means
        let sources = context.availableSources()
        let sourceItems = sources.map { source -> String in
            switch source {
            case "original": return "\(source)  \(ANSI.dim)— file metadata loaded at import\(ANSI.reset)"
            case "read": return "\(source)  \(ANSI.dim)— file metadata loaded on demand\(ANSI.reset)"
            default: return "\(source)  \(ANSI.dim)— dependency plugin\(ANSI.reset)"
            }
        }
        guard let sourceIdx = terminal.selectFromList(
            title: "Where is the field you want to match?",
            items: sourceItems
        ) else { return nil }
        let source = sources[sourceIdx]

        // Step 2: Select field — filterable list without namespace prefix
        let fields = context.fields(in: source)
        let fieldItems = fields.map(\.name)
        guard let fieldIdx = terminal.selectFromFilterableList(
            title: "Select field",
            items: fieldItems
        ) else { return nil }
        let selectedField = fields[fieldIdx]

        // Step 3: Enter pattern
        guard let pattern = terminal.promptForInput(
            title: "Enter match pattern for \(selectedField.name)",
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

        // Step 4: Actions (emit)
        if existing != nil {
            builder.reset()
            _ = builder.setMatch(field: selectedField.qualifiedName, pattern: pattern)
        }

        let matchDesc = "\(selectedField.name) ~ \(pattern)"
        if !addActions(to: &builder, isWrite: false, matchContext: matchDesc) {
            return nil
        }

        // Step 5: Write actions
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

    private func addActions(to builder: inout RuleBuilder, isWrite: Bool, matchContext: String) -> Bool {
        let actions = ["add", "remove", "replace", "removeField", "clone"]
        let label = isWrite ? "write action" : "action"
        let whenLine = "\(ANSI.dim)When \(matchContext)\(ANSI.reset)"

        while true {
            guard let actionIdx = terminal.selectFromList(
                title: "\(whenLine)\nSelect \(label)  \(ANSI.dim)(Esc when done)\(ANSI.reset)",
                items: actions
            ) else { break }

            let action = actions[actionIdx]

            guard let config = promptForEmitConfig(action: action) else { continue }
            let result = isWrite ? builder.addWrite(config) : builder.addEmit(config)
            if case let .failure(error) = result {
                showError(error)
                continue
            }

            if !terminal.confirm("Add another \(label)?") { break }
        }
        return true
    }

    private func addWriteActions(to builder: inout RuleBuilder, matchContext: String) -> Bool {
        if !terminal.confirm("Add write actions (modify file metadata)?") { return true }
        return addActions(to: &builder, isWrite: true, matchContext: matchContext)
    }

    private func promptForEmitConfig(action: String) -> EmitConfig? {
        // Build autocomplete from catalog fields + fields already used in existing rules
        var fieldSet = Set<String>()

        // Catalog fields (EXIF:ISO, TIFF:Make, IPTC:Keywords, etc.)
        for source in context.availableSources() {
            for field in context.fields(in: source) {
                fieldSet.insert(field.name)
            }
        }

        // Fields already used in existing rules (emit + write targets, match fields)
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

        let uniqueFields = fieldSet.sorted()

        var field: String
        while true {
            guard let input = terminal.promptWithAutocomplete(
                title: "Target field for \(action)",
                hint: "The field to modify (e.g. keywords, IPTC:Keywords)",
                completions: uniqueFields,
                browsableList: uniqueFields
            ) else { return nil }

            if uniqueFields.contains(input) || terminal.confirm("'\(input)' is a new field name. Use it anyway?") {
                field = input
                break
            }
        }

        switch action {
        case "add", "remove":
            var values: [String] = []
            while true {
                let ordinal = values.isEmpty ? "first" : "next"
                let hint = values.isEmpty
                    ? "e.g. sony  or  regex:.*\\d+mm.*"
                    : "Enter another value, or press Enter to finish"
                guard let value = terminal.promptForInput(
                    title: "Enter \(ordinal) value",
                    hint: hint,
                    allowEmpty: !values.isEmpty
                ) else {
                    // Esc pressed: cancel if no values yet, otherwise finish with what we have
                    if values.isEmpty { return nil }
                    break
                }
                if value.isEmpty { break }
                values.append(value)
            }
            if values.isEmpty { return nil }
            return EmitConfig(action: action, field: field, values: values, replacements: nil, source: nil)

        case "replace":
            guard let pattern = terminal.promptForInput(
                title: "Replacement pattern",
                hint: "Pattern to match in values"
            ) else { return nil }
            guard let replacement = terminal.promptForInput(
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
            guard let source = terminal.promptForInput(
                title: "Clone source",
                hint: "source:field (e.g. original:IPTC:Keywords) or source name for wildcard"
            ) else { return nil }
            return EmitConfig(action: action, field: field, values: nil, replacements: nil, source: source)

        default:
            return nil
        }
    }
}
