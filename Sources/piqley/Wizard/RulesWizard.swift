import Foundation
import PiqleyCore

/// ANSI-based interactive rule editor wizard.
/// Uses raw terminal mode with cursor-positioned selection lists.
final class RulesWizard {
    var context: RuleEditingContext
    let pluginDir: URL
    let terminal: RawTerminal
    let dependencyIdentifiers: Set<String>
    var modified = false
    var savedAt: Date?

    /// Tracks which rules are marked for deletion (by stage + slot + index).
    /// Deleted rules are shown struck-through and removed on save.
    var deletedRules: Set<String> = []

    init(context: RuleEditingContext, pluginDir: URL, dependencyIdentifiers: Set<String> = []) {
        self.context = context
        self.pluginDir = pluginDir
        self.dependencyIdentifiers = dependencyIdentifiers
        terminal = RawTerminal()
    }

    func run() throws {
        defer { terminal.restore() }
        stageSelect()
    }

    func footerWithSaveIndicator(_ base: String) -> String {
        if let savedAt, Date().timeIntervalSince(savedAt) < 2 {
            return "\(ANSI.green)\(ANSI.bold)Saved\(ANSI.reset)  \(base)"
        }
        return base
    }

    /// Read a key, using a timeout to clear the save indicator if one is active.
    func readKeyWithSaveTimeout() -> Key {
        if let savedAt {
            let remaining = 2.0 - Date().timeIntervalSince(savedAt)
            if remaining > 0 {
                let key = terminal.readKey(timeoutMs: Int32(remaining * 1000))
                if key == .timeout {
                    self.savedAt = nil
                    return .timeout
                }
                return key
            }
            self.savedAt = nil
        }
        return terminal.readKey()
    }

    // MARK: - Namespace Validation

    /// Extracts all namespace prefixes referenced by rules across all stages.
    /// Splits match fields and clone source references on the first `:`.
    static func extractReferencedNamespaces(from stages: [String: StageConfig]) -> Set<String> {
        var namespaces = Set<String>()

        func extractNamespace(from qualifiedField: String) -> String? {
            guard let colonIndex = qualifiedField.firstIndex(of: ":") else { return nil }
            let namespace = String(qualifiedField[qualifiedField.startIndex ..< colonIndex])
            return namespace.isEmpty ? nil : namespace
        }

        func processEmitConfigs(_ configs: [EmitConfig]) {
            for config in configs {
                if let source = config.source,
                   let namespace = extractNamespace(from: source)
                {
                    namespaces.insert(namespace)
                }
            }
        }

        for (_, stage) in stages {
            let allRules = (stage.preRules ?? []) + (stage.postRules ?? [])
            for rule in allRules {
                if let namespace = extractNamespace(from: rule.match.field) {
                    namespaces.insert(namespace)
                }
                processEmitConfigs(rule.emit)
                processEmitConfigs(rule.write)
            }
        }

        return namespaces
    }

    /// Returns the set of plugin namespaces that are NOT declared dependencies
    /// (filtering out built-in namespaces).
    static func nonDependencyNamespaces(
        _ referenced: Set<String>,
        dependencies: Set<String>
    ) -> Set<String> {
        // Future: replace "read" with ReservedName.read once PiqleyCore publishes that constant
        let builtIn: Set<String> = [ReservedName.original, "read"]
        return referenced.subtracting(builtIn).subtracting(dependencies)
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
                footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  \u{23CE} select  s save  Esc quit")
            )

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                slotSelect(stageName: stageNames[cursor])
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

    func slotRuleList(stageName: String, slot: RuleSlot) {
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
                title: "\(stageName) \(slot == .pre ? "pre" : "post")-rules",
                items: items,
                cursor: cursor,
                footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  a add  e edit  \(deleteLabel)  r reorder  s save  Esc back")
            )

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
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

    func promptForEmitConfig(action: String) -> EmitConfig? {
        let uniqueFields = buildFieldCompletions()

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
