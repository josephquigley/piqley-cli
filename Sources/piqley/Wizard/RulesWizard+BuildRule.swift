import Foundation
import PiqleyCore

extension RulesWizard {
    // MARK: - Build Rule (wizard flow)

    func buildRule(editing existing: Rule? = nil) -> Rule? {
        if let existing {
            return editRuleMenu(existing: existing)
        }

        let ruleTypes = ["add", "add (when matching)", "replace", "remove from", "remove field", "clone"]
        guard let typeIdx = terminal.selectFromList(
            title: "Select rule type",
            items: ruleTypes
        ) else { return nil }

        switch typeIdx {
        case 0:
            return buildUnconditionalRule()
        case 1:
            return buildConditionalRule(action: "add")
        case 2:
            return buildConditionalRule(action: "replace")
        case 3:
            return buildConditionalRule(action: "remove")
        case 4:
            return buildConditionalRule(action: "removeField")
        case 5:
            return buildConditionalRule(action: "clone")
        default:
            return nil
        }
    }

    private func buildUnconditionalRule() -> Rule? {
        var builder = RuleBuilder(context: context)

        // Prompt for emit config
        guard let config = promptForEmitConfig(action: "add") else { return nil }
        if case let .failure(error) = builder.addEmit(config) {
            showError(error)
            return nil
        }

        // Write actions
        if terminal.confirm("Add write actions (modify file metadata)?") {
            promptForWriteActions(builder: &builder, contextLine: nil)
        }

        switch builder.build() {
        case let .success(rule):
            return rule
        case let .failure(error):
            showError(error)
            return nil
        }
    }

    private func buildConditionalRule(action: String) -> Rule? {
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

        // Step 3: Prompt for emit config
        let matchDesc = "\(selected.qualifiedName) ~ \(pattern)"
        let whenLine = "\(ANSI.dim)When \(matchDesc)\(ANSI.reset)"

        guard let config = promptForEmitConfig(action: action) else { return nil }
        if case let .failure(error) = builder.addEmit(config) {
            showError(error)
            return nil
        }

        // Additional emit actions
        let emitActions = ["add", "remove", "replace", "removeField", "clone"]
        while terminal.confirm("Add another action?") {
            guard let actionIdx = terminal.selectFromList(
                title: "\(whenLine)\nSelect action  \(ANSI.dim)(Esc when done)\(ANSI.reset)",
                items: emitActions
            ) else { break }

            let nextAction = emitActions[actionIdx]
            guard let nextConfig = promptForEmitConfig(action: nextAction) else { continue }
            if case let .failure(error) = builder.addEmit(nextConfig) {
                showError(error)
                continue
            }
        }

        // Step 4: Write actions
        if terminal.confirm("Add write actions (modify file metadata)?") {
            promptForWriteActions(builder: &builder, contextLine: whenLine)
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

    private func promptForWriteActions(builder: inout RuleBuilder, contextLine: String?) {
        let writeActions = ["add", "remove", "replace", "removeField", "clone"]
        while true {
            let title = if let contextLine {
                "\(contextLine)\nSelect write action type  \(ANSI.dim)(Esc when done)\(ANSI.reset)"
            } else {
                "Select write action type  \(ANSI.dim)(Esc when done)\(ANSI.reset)"
            }

            guard let actionIdx = terminal.selectFromList(
                title: title,
                items: writeActions
            ) else { break }

            let action = writeActions[actionIdx]
            guard let writeConfig = promptForEmitConfig(action: action) else { continue }
            if case let .failure(error) = builder.addWrite(writeConfig) {
                showError(error)
                continue
            }

            if !terminal.confirm("Add another write action?") { break }
        }
    }

    func promptForEmitConfig(action: String) -> EmitConfig? {
        let (uniqueFields, readOnlyCount) = buildWritableFieldCompletions()

        let readOnlyNote: String? = readOnlyCount > 0
            ? "\(readOnlyCount) read-only field\(readOnlyCount == 1 ? "" : "s") not shown"
            : nil

        var field: String
        while true {
            let verb = actionFieldVerb(action)
            guard let input = terminal.promptWithAutocomplete(
                title: "Target field for \(action)",
                hint: "The field to \(verb) (e.g. keywords, original:IPTC:Keywords)",
                completions: uniqueFields,
                browsableList: uniqueFields,
                noMatchHint: "Enter will create a new field with this name",
                subtitleNote: readOnlyNote
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
            let qualifiedCompletions = buildQualifiedFieldCompletions()
            guard let source = terminal.promptWithAutocomplete(
                title: "Clone source",
                hint: "(e.g. original:IPTC:Keywords) or a source name to clone all its fields",
                completions: qualifiedCompletions,
                browsableList: qualifiedCompletions,
                noMatchHint: "Enter will use this field name as-is"
            ) else { return nil }
            return EmitConfig(action: action, field: field, values: nil, replacements: nil, source: source)

        default:
            return nil
        }
    }
}
