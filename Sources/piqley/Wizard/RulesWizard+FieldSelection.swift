import Foundation
import PiqleyCore

extension RulesWizard {
    /// Prompts for source then field selection. Returns the qualified name and display name,
    /// or nil if the user cancels.
    func selectField() -> (qualifiedName: String, displayName: String)? {
        let sources = context.availableSources()
        let sourceItems = sources.map { source -> String in
            switch source {
            case "original": return "\(source)  \(ANSI.dim)\u{2014} file metadata loaded at import\(ANSI.reset)"
            case "read": return "\(source)  \(ANSI.dim)\u{2014} file metadata loaded on demand\(ANSI.reset)"
            default: return "\(source)  \(ANSI.dim)\u{2014} plugin\(ANSI.reset)"
            }
        }
        guard let sourceIdx = terminal.selectFromList(
            title: "Where is the field you want to match?",
            items: sourceItems
        ) else { return nil }
        let source = sources[sourceIdx]

        let fields = context.fields(in: source)
        let fieldItems = fields.map(\.name)
        guard let fieldIdx = terminal.selectFromFilterableList(
            title: "Select field",
            items: fieldItems
        ) else { return nil }
        let selectedField = fields[fieldIdx]
        return (qualifiedName: selectedField.qualifiedName, displayName: selectedField.name)
    }

    /// Builds a sorted list of field names for autocomplete, combining catalog fields
    /// and fields already used in existing rules.
    func buildFieldCompletions() -> [String] {
        var fieldSet = Set<String>()
        for source in context.availableSources() {
            for field in context.fields(in: source) {
                fieldSet.insert(field.name)
            }
        }
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
        return fieldSet.sorted()
    }
}
