import Foundation
import PiqleyCore

extension RulesWizard {
    /// Shows a navigable menu for editing an existing rule's components individually.
    /// Returns the modified Rule on Save, or nil on Esc (cancel).
    func editRuleMenu(existing: Rule) -> Rule? {
        var state = EditRuleState(
            matchField: existing.match?.field,
            matchPattern: existing.match?.pattern,
            matchNot: existing.match?.not,
            emitActions: existing.emit,
            writeActions: existing.write
        )
        var cursor = 0

        while true {
            let items = buildEditRuleMenuItems(state: state)
            cursor = min(cursor, items.labels.count - 1)
            let matchDesc = if let matchField = state.matchField, let matchPattern = state.matchPattern {
                "\(resolveFieldDisplayName(matchField)) ~ \(matchPattern)"
            } else {
                "add (constant)"
            }

            terminal.drawScreen(
                title: "Edit rule: \(matchDesc)",
                items: items.labels,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} edit  d delete  s save  Esc cancel"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp:
                cursor = max(0, cursor - 1)
            case .cursorDown:
                cursor = min(items.labels.count - 1, cursor + 1)
            case .enter:
                if let result = handleEditRuleMenuEnter(tag: items.tags[cursor], state: &state) {
                    return result
                }
            case .char("d"):
                handleEditRuleMenuDelete(tag: items.tags[cursor], state: &state)
            case .char("s"):
                if let result = trySaveRule(state: state) {
                    return result
                }
            case .escape:
                return nil
            default:
                break
            }
        }
    }

    // MARK: - State

    struct EditRuleState {
        var matchField: String?
        var matchPattern: String?
        var matchNot: Bool?
        var emitActions: [EmitConfig]
        var writeActions: [EmitConfig]
    }

    // MARK: - Menu Item Construction

    enum EditRuleMenuTag {
        case matchField, matchPattern, matchNegated
        case emit(Int), addEmit
        case write(Int), addWrite
    }

    struct EditRuleMenuItems {
        var labels: [String]
        var tags: [EditRuleMenuTag]
    }

    func resolveFieldDisplayName(_ qualifiedName: String) -> String {
        for source in context.availableSources() {
            for field in context.fields(in: source) where field.qualifiedName == qualifiedName {
                return field.name
            }
        }
        return qualifiedName
    }

    func buildEditRuleMenuItems(state: EditRuleState) -> EditRuleMenuItems {
        var labels: [String] = []
        var tags: [EditRuleMenuTag] = []

        if let matchField = state.matchField {
            labels.append("Field: \(resolveFieldDisplayName(matchField))")
            tags.append(.matchField)

            labels.append("Pattern: \(state.matchPattern ?? "")")
            tags.append(.matchPattern)

            labels.append("Negated: \(state.matchNot == true ? "yes" : "no")")
            tags.append(.matchNegated)
        } else {
            labels.append("\(ANSI.dim)Type: add (constant)\(ANSI.reset)")
            tags.append(.matchField)
        }

        for (idx, emit) in state.emitActions.enumerated() {
            labels.append(formatEmitAction(emit))
            tags.append(.emit(idx))
        }
        labels.append("\(ANSI.dim)+ Add action\(ANSI.reset)")
        tags.append(.addEmit)

        for (idx, write) in state.writeActions.enumerated() {
            labels.append("write: \(formatEmitAction(write))")
            tags.append(.write(idx))
        }
        labels.append("\(ANSI.dim)+ Add write action\(ANSI.reset)")
        tags.append(.addWrite)

        return EditRuleMenuItems(labels: labels, tags: tags)
    }

    // MARK: - Enter Key Handling

    /// Returns `.some(rule)` if the user saved successfully, `.some(nil)` on save validation failure
    /// (to stay in loop and let user fix), or `nil` for non-save actions (continue loop).
    func handleEditRuleMenuEnter(tag: EditRuleMenuTag, state: inout EditRuleState) -> Rule?? {
        switch tag {
        case .matchField:
            if let selected = selectField() {
                state.matchField = selected.qualifiedName
            }
            return nil

        case .matchPattern:
            if let newPattern = terminal.promptForInput(
                title: "Enter match pattern for \(resolveFieldDisplayName(state.matchField ?? ""))",
                hint: "Plain text = exact match. Prefix with glob: or regex: for advanced.",
                defaultValue: state.matchPattern
            ) {
                state.matchPattern = newPattern
            }
            return nil

        case .matchNegated:
            state.matchNot = (state.matchNot == true) ? nil : true
            return nil

        case let .emit(idx):
            if let edited = editAction(state.emitActions[idx]) {
                state.emitActions[idx] = edited
            }
            return nil

        case .addEmit:
            addEmitToList(&state.emitActions)
            return nil

        case let .write(idx):
            if let edited = editAction(state.writeActions[idx]) {
                state.writeActions[idx] = edited
            }
            return nil

        case .addWrite:
            addEmitToList(&state.writeActions, title: "Select write action type")
            return nil
        }
    }

    private func addEmitToList(_ list: inout [EmitConfig], title: String = "Select action type") {
        let actions = ["add", "remove", "replace", "removeField", "clone"]
        if let actionIdx = terminal.selectFromList(title: title, items: actions) {
            if let config = promptForEmitConfig(action: actions[actionIdx]) {
                list.append(config)
            }
        }
    }

    /// Returns Rule?? — outer optional is nil if validation failed (continue loop),
    /// inner optional is the saved Rule on success.
    private func trySaveRule(state: EditRuleState) -> Rule?? {
        var builder = RuleBuilder(context: context)

        if let matchField = state.matchField, let matchPattern = state.matchPattern {
            let matchResult = builder.setMatch(field: matchField, pattern: matchPattern)
            if case let .failure(error) = matchResult {
                showError(error)
                return nil
            }
        }

        for emit in state.emitActions {
            if case let .failure(error) = builder.addEmit(emit) {
                showError(error)
                return nil
            }
        }
        for write in state.writeActions {
            if case let .failure(error) = builder.addWrite(write) {
                showError(error)
                return nil
            }
        }
        switch builder.build() {
        case .success:
            let match: MatchConfig? = if let matchField = state.matchField, let matchPattern = state.matchPattern {
                MatchConfig(field: matchField, pattern: matchPattern, not: state.matchNot)
            } else {
                nil
            }
            let rule = Rule(match: match, emit: state.emitActions, write: state.writeActions)
            return .some(rule)
        case let .failure(error):
            showError(error)
            return nil
        }
    }

    // MARK: - Delete Key Handling

    func handleEditRuleMenuDelete(tag: EditRuleMenuTag, state: inout EditRuleState) {
        switch tag {
        case let .emit(idx):
            state.emitActions.remove(at: idx)
        case let .write(idx):
            state.writeActions.remove(at: idx)
        default:
            break
        }
    }
}
