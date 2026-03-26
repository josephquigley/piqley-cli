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

    /// Formats available sources as inline tags for display above field prompts.
    func formatSourceTags() -> String {
        let sources = context.availableSources()
        let tags = sources.map { "\(ANSI.dim)[\(ANSI.reset)\($0)\(ANSI.dim)]\(ANSI.reset)" }
        return tags.joined(separator: " ")
    }

    /// Builds a sorted list of field names for autocomplete, combining catalog fields
    /// and fields already used in existing rules. The plugin's own fields are listed
    /// first, then everything else alphabetically.
    func buildFieldCompletions() -> [String] {
        var ownFields = Set<String>()
        var otherFields = Set<String>()
        let pluginID = context.pluginIdentifier
        for source in context.availableSources() {
            for field in context.fields(in: source) {
                if source == pluginID {
                    ownFields.insert(field.name)
                } else {
                    otherFields.insert(field.name)
                }
            }
        }
        for stageName in context.stageNames() {
            for slot in [RuleSlot.pre, .post] {
                for rule in context.rules(forStage: stageName, slot: slot) {
                    for emit in rule.emit {
                        if let field = emit.field { ownFields.insert(field) }
                    }
                    for write in rule.write {
                        if let field = write.field { ownFields.insert(field) }
                    }
                }
            }
        }
        otherFields.subtract(ownFields)
        return ownFields.sorted() + otherFields.sorted()
    }

    /// Builds completions with all qualified names (source:field) for use in
    /// prompts where the user needs to specify a fully qualified field reference.
    func buildQualifiedFieldCompletions() -> [String] {
        var fieldSet = Set<String>()
        for source in context.availableSources() {
            for field in context.fields(in: source) {
                fieldSet.insert(field.qualifiedName)
            }
            // Also include bare source name for wildcard clone
            fieldSet.insert(source)
        }
        // Include fields emitted/written by the plugin's own rules, qualified
        // with the plugin's namespace
        let pluginID = context.pluginIdentifier
        for stageName in context.stageNames() {
            for slot in [RuleSlot.pre, .post] {
                for rule in context.rules(forStage: stageName, slot: slot) {
                    for emit in rule.emit {
                        if let field = emit.field {
                            fieldSet.insert("\(pluginID):\(field)")
                        }
                    }
                    for write in rule.write {
                        if let field = write.field {
                            fieldSet.insert("\(pluginID):\(field)")
                        }
                    }
                }
            }
        }
        return fieldSet.sorted()
    }
}
