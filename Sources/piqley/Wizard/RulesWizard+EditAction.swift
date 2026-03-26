import Foundation
import PiqleyCore

extension RulesWizard {
    // MARK: - Edit Action

    /// Shows a sub-menu for editing an individual emit/write action.
    /// Returns the modified EmitConfig on Done, or nil on Esc (cancel).
    func editAction(_ config: EmitConfig) -> EmitConfig? {
        var state = EditActionState(config: config)
        var cursor = 0

        while true {
            let menuItems = buildEditActionMenu(state: state)
            let items = menuItems.map(\.label)
            cursor = min(cursor, items.count - 1)

            terminal.drawScreen(
                title: "Edit action: \(state.action) \(state.field)",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} edit  d delete value  Esc back"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp:
                cursor = max(0, cursor - 1)

            case .cursorDown:
                cursor = min(items.count - 1, cursor + 1)

            case .enter:
                let tag = menuItems[cursor].tag
                if let result = handleEditActionEnter(tag: tag, state: &state) {
                    return result
                }

            case .char("d"):
                let tag = menuItems[cursor].tag
                handleEditActionDelete(tag: tag, state: &state)

            case .escape:
                return nil

            default:
                break
            }
        }
    }

    // MARK: - Edit Action Helpers

    private func buildEditActionMenu(state: EditActionState) -> [(label: String, tag: EditActionTag)] {
        var items: [(label: String, tag: EditActionTag)] = []
        items.append(("Type: \(state.action)", .actionType))
        items.append(("Field: \(state.field)", .field))
        items.append(("Negated: \(state.not == true ? "yes" : "no")", .negated))

        switch state.action {
        case "add", "remove":
            for (idx, val) in state.values.enumerated() {
                items.append(("Value: \(val)", .value(idx)))
            }
            items.append(("\(ANSI.dim)+ Add value\(ANSI.reset)", .addValue))

        case "replace":
            for (idx, rep) in state.replacements.enumerated() {
                items.append(("Pattern: \(rep.pattern) \u{2192} \(rep.replacement)", .pattern(idx)))
            }
            items.append(("\(ANSI.dim)+ Add replacement\(ANSI.reset)", .addValue))

        case "clone":
            items.append(("Source: \(state.source)", .cloneSource))

        default:
            break
        }

        items.append(("\(ANSI.bold)Done\(ANSI.reset)", .done))
        return items
    }

    private func handleEditActionEnter(tag: EditActionTag, state: inout EditActionState) -> EmitConfig?? {
        switch tag {
        case .actionType:
            handleActionTypeSelection(state: &state)

        case .field:
            let completions = buildFieldCompletions()
            let verb = actionFieldVerb(state.action)
            let sourcesTags = formatSourceTags()
            if let input = terminal.promptWithAutocomplete(
                title: "Target field for \(state.action)",
                hint: "\(sourcesTags)\nThe field to \(verb) (e.g. keywords, IPTC:Keywords)",
                completions: completions,
                browsableList: completions,
                defaultValue: state.field,
                noMatchHint: "Enter will create a new field with this name"
            ) {
                state.field = input
            }

        case .negated:
            state.not = (state.not == true) ? nil : true

        case let .value(idx):
            if let newVal = terminal.promptForInput(
                title: "Edit value",
                hint: "Enter new value",
                defaultValue: state.values[idx]
            ) {
                state.values[idx] = newVal
            }

        case .addValue:
            handleAddValue(state: &state)

        case let .pattern(idx):
            let rep = state.replacements[idx]
            if let pat = terminal.promptForInput(
                title: "Replacement pattern",
                hint: "Pattern to match in values",
                defaultValue: rep.pattern
            ), let repStr = terminal.promptForInput(
                title: "Replacement string",
                hint: "What to replace with (use $1, $2 for capture groups)",
                defaultValue: rep.replacement
            ) {
                state.replacements[idx] = Replacement(pattern: pat, replacement: repStr)
            }

        case .cloneSource:
            let completions = buildQualifiedFieldCompletions()
            if let src = terminal.promptWithAutocomplete(
                title: "Clone source",
                hint: "(e.g. original:IPTC:Keywords) or a source name to clone all its fields",
                completions: completions,
                browsableList: completions,
                defaultValue: state.source,
                noMatchHint: "Enter will use this field name as-is"
            ) {
                state.source = src
            }

        case .done:
            let built = buildEmitConfig(from: state)
            let result = context.validateEmit(built)
            if case let .failure(error) = result {
                showError(error)
                return nil // stay in loop, validation failed
            }
            return .some(built) // signal: return this config
        }

        return nil // signal: stay in loop
    }

    private func handleEditActionDelete(tag: EditActionTag, state: inout EditActionState) {
        switch tag {
        case let .value(idx):
            state.values.remove(at: idx)
        case let .pattern(idx):
            state.replacements.remove(at: idx)
        default:
            break
        }
    }

    private func handleActionTypeSelection(state: inout EditActionState) {
        let actions = ["add", "remove", "replace", "removeField", "clone"]
        guard let idx = terminal.selectFromList(title: "Select action type", items: actions) else { return }
        let newAction = actions[idx]
        guard newAction != state.action else { return }

        state.action = newAction
        state.values = []
        state.replacements = []
        state.source = ""

        switch newAction {
        case "add", "remove":
            if let val = terminal.promptForInput(
                title: "Enter first value",
                hint: "e.g. sony  or  regex:.*\\d+mm.*"
            ) {
                state.values.append(val)
            }
        case "replace":
            if let pat = terminal.promptForInput(
                title: "Replacement pattern",
                hint: "Pattern to match in values"
            ), let rep = terminal.promptForInput(
                title: "Replacement string",
                hint: "What to replace with (use $1, $2 for capture groups)"
            ) {
                state.replacements.append(Replacement(pattern: pat, replacement: rep))
            }
        case "clone":
            let qualifiedCompletions = buildQualifiedFieldCompletions()
            if let src = terminal.promptWithAutocomplete(
                title: "Clone source",
                hint: "(e.g. original:IPTC:Keywords) or a source name to clone all its fields",
                completions: qualifiedCompletions,
                browsableList: qualifiedCompletions,
                defaultValue: "",
                noMatchHint: "Enter will use this field name as-is"
            ) {
                state.source = src
            }
        default:
            break
        }
    }

    private func handleAddValue(state: inout EditActionState) {
        if state.action == "replace" {
            if let pat = terminal.promptForInput(
                title: "Replacement pattern",
                hint: "Pattern to match in values"
            ), let repStr = terminal.promptForInput(
                title: "Replacement string",
                hint: "What to replace with (use $1, $2 for capture groups)"
            ) {
                state.replacements.append(Replacement(pattern: pat, replacement: repStr))
            }
        } else {
            if let val = terminal.promptForInput(
                title: "Enter value",
                hint: "e.g. sony  or  regex:.*\\d+mm.*"
            ) {
                state.values.append(val)
            }
        }
    }

    private func buildEmitConfig(from state: EditActionState) -> EmitConfig {
        switch state.action {
        case "add", "remove":
            EmitConfig(action: state.action, field: state.field, values: state.values, replacements: nil, source: nil, not: state.not)
        case "replace":
            EmitConfig(action: state.action, field: state.field, values: nil, replacements: state.replacements, source: nil, not: state.not)
        case "clone":
            EmitConfig(action: state.action, field: state.field, values: nil, replacements: nil, source: state.source, not: state.not)
        default:
            EmitConfig(action: state.action, field: state.field, values: nil, replacements: nil, source: nil, not: state.not)
        }
    }
}

// MARK: - Supporting Types

private enum EditActionTag {
    case actionType, field, negated
    case value(Int), addValue
    case pattern(Int)
    case cloneSource
    case done
}

private struct EditActionState {
    var action: String
    var field: String
    var not: Bool?
    var values: [String]
    var replacements: [Replacement]
    var source: String

    init(config: EmitConfig) {
        action = config.action ?? "add"
        field = config.field ?? ""
        not = config.not
        values = config.values ?? []
        replacements = config.replacements ?? []
        source = config.source ?? ""
    }
}
