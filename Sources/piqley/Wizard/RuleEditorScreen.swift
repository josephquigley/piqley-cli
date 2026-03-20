import PiqleyCore
import TermKit

/// Screen: multi-step rule creation/editing with pinned context.
/// Steps: source -> field -> pattern -> emit actions -> write actions -> confirm
@MainActor
final class RuleEditorScreen {
    let context: RuleEditingContext
    private let stageName: String
    private let slot: RuleSlot
    private let editingIndex: Int?

    init(context: RuleEditingContext, stageName: String, slot: RuleSlot, editingIndex: Int?) {
        self.context = context
        self.stageName = stageName
        self.slot = slot
        self.editingIndex = editingIndex
    }

    func present(onComplete: @escaping (Rule?) -> Void) {
        var builder = RuleBuilder(context: context)

        // If editing, pre-populate
        if let index = editingIndex {
            let existing = context.rules(forStage: stageName, slot: slot)[index]
            _ = builder.setMatch(field: existing.match.field, pattern: existing.match.pattern)
            for emit in existing.emit {
                _ = builder.addEmit(emit)
            }
            for write in existing.write {
                _ = builder.addWrite(write)
            }
        }

        showSourceSelection(builder: builder, onComplete: onComplete)
    }

    // MARK: - Step 1: Source Selection

    private func showSourceSelection(builder: RuleBuilder, onComplete: @escaping (Rule?) -> Void) {
        let sources = context.availableSources()
        let sourceDescriptions = sources.map { source -> String in
            switch source {
            case "original": return "original -- file metadata (available at load)"
            case "read": return "read -- file metadata (loaded on demand)"
            default: return "\(source) -- dependency plugin"
            }
        }

        let top = makeWizardToplevel()

        let win = WizardWindow("New Rule: Select Source")
        win.fill()
        top.addSubview(win)

        let hint = Label("  Select the source to match against:")
        hint.x = Pos.at(0)
        hint.y = Pos.at(0)
        hint.width = Dim.fill()
        win.addSubview(hint)

        let list = ListView(items: sourceDescriptions)
        list.x = Pos.at(1)
        list.y = Pos.at(2)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)
        list.allowMarking = false
        list.selectedMarker = "> "
        win.addSubview(list)

        let footer = Label("  \u{2191}\u{2193} navigate   \u{23CE} select   Esc cancel")
        footer.x = Pos.at(0)
        footer.y = Pos.bottom(of: list) + 1
        footer.width = Dim.fill()
        win.addSubview(footer)

        list.activate = { [weak self] index in
            guard let self, index < sources.count else { return true }
            let selectedSource = sources[index]
            Application.requestStop()
            showFieldSelection(source: selectedSource, builder: builder, onComplete: onComplete)
            return true
        }

        win.onKey = { event in
            if event.key == .esc {
                Application.requestStop()
                onComplete(nil)
                return true
            }
            return false
        }

        Application.present(top: top)
    }

    // MARK: - Step 2: Field Selection

    private func showFieldSelection(
        source: String, builder: RuleBuilder, onComplete: @escaping (Rule?) -> Void
    ) {
        let fields = context.fields(in: source)
        var displayFields = fields
        var filterText = ""
        var filterActive = false

        let top = makeWizardToplevel()

        let win = WizardWindow("New Rule: Select Field")
        win.fill()
        top.addSubview(win)

        let contextLabel = Label("  Match: \(source):")
        contextLabel.x = Pos.at(0)
        contextLabel.y = Pos.at(0)
        contextLabel.width = Dim.fill()
        win.addSubview(contextLabel)

        let filterLabel = Label("  Filter: ")
        filterLabel.x = Pos.at(0)
        filterLabel.y = Pos.at(1)
        win.addSubview(filterLabel)

        let filterField = TextField("")
        filterField.x = Pos.at(10)
        filterField.y = Pos.at(1)
        filterField.width = Dim.fill(1)
        filterField.canFocus = false
        win.addSubview(filterField)

        func buildFieldItems() -> [String] {
            var items: [String] = []
            var lastCategory: FieldCategory?
            for field in displayFields {
                if field.category != lastCategory {
                    items.append("--- \(Self.categoryName(field.category)) ---")
                    lastCategory = field.category
                }
                items.append("  \(field.name)")
            }
            if items.isEmpty {
                items.append("(no fields match)")
            }
            return items
        }

        // Map from list index to field index (skipping category headers)
        func fieldIndex(for listIndex: Int) -> Int? {
            var fieldIdx = -1
            let items = buildFieldItems()
            for idx in 0 ..< items.count {
                if !items[idx].hasPrefix("---"), !items[idx].hasPrefix("(") {
                    fieldIdx += 1
                    if idx == listIndex { return fieldIdx }
                }
            }
            return nil
        }

        let list = ListView(items: buildFieldItems())
        list.x = Pos.at(1)
        list.y = Pos.at(2)
        list.width = Dim.fill(1)
        list.height = Dim.fill(4)
        list.allowMarking = false
        list.selectedMarker = "> "
        win.addSubview(list)

        let footer = Label(
            "  \u{2191}\u{2193} navigate   \u{23CE} select   f filter   t custom field   Esc cancel"
        )
        footer.x = Pos.at(0)
        footer.y = Pos.bottom(of: list) + 1
        footer.width = Dim.fill()
        win.addSubview(footer)

        filterField.textChanged = { _, _ in
            filterText = filterField.text
            if filterText.isEmpty {
                displayFields = fields
            } else {
                let query = filterText.lowercased()
                displayFields = fields.filter { $0.name.lowercased().contains(query) }
            }
            list.items = buildFieldItems()
            list.setNeedsDisplay()
        }

        list.activate = { [weak self] index in
            guard let self else { return true }
            if let fIdx = fieldIndex(for: index), fIdx < displayFields.count {
                let field = displayFields[fIdx]
                Application.requestStop()
                showPatternInput(
                    source: source,
                    fieldName: field.qualifiedName,
                    builder: builder,
                    onComplete: onComplete
                )
            }
            return true
        }

        win.onKey = { [weak self] event in
            switch event.key {
            case .esc:
                if filterActive {
                    filterActive = false
                    filterField.canFocus = false
                    filterField.text = ""
                    filterText = ""
                    displayFields = fields
                    list.items = buildFieldItems()
                    list.setNeedsDisplay()
                    _ = list.becomeFirstResponder()
                    return true
                }
                Application.requestStop()
                onComplete(nil)
                return true

            case .letter("f"):
                if !filterActive {
                    filterActive = true
                    filterField.canFocus = true
                    _ = filterField.becomeFirstResponder()
                    return true
                }
                return false

            case .letter("t"):
                if !filterActive {
                    guard let self else { return false }
                    showCustomFieldInput(source: source, builder: builder, onComplete: onComplete)
                    return true
                }
                return false

            default:
                return false
            }
        }

        Application.present(top: top)
    }

    private func showCustomFieldInput(
        source: String, builder: RuleBuilder, onComplete: @escaping (Rule?) -> Void
    ) {
        let dialog = Dialog(title: "Custom Field Name", width: 60, height: 8, buttons: [])

        let nameField = TextField("")
        nameField.x = Pos.at(1)
        nameField.y = Pos.at(1)
        nameField.width = Dim.fill(1)
        dialog.addSubview(nameField)

        let okBtn = Button("OK")
        let cancelBtn = Button("Cancel") { Application.requestStop() }

        okBtn.clicked = { [weak self] _ in
            guard let self else { return }
            let customName = nameField.text.trimmingCharacters(in: .whitespaces)
            if !customName.isEmpty {
                let qualifiedName = "\(source):\(customName)"
                Application.requestStop() // close dialog
                Application.requestStop() // close field selection
                showPatternInput(
                    source: source,
                    fieldName: qualifiedName,
                    builder: builder,
                    onComplete: onComplete
                )
            }
        }
        dialog.addButton(okBtn)
        dialog.addButton(cancelBtn)
        Application.present(top: dialog)
    }

    // MARK: - Step 3: Pattern Input

    private func showPatternInput(
        source _: String,
        fieldName: String,
        builder: RuleBuilder,
        onComplete: @escaping (Rule?) -> Void
    ) {
        let top = makeWizardToplevel()

        let win = WizardWindow("New Rule: Enter Pattern")
        win.fill()
        top.addSubview(win)

        let contextLabel = Label("  Match: \(fieldName) ~")
        contextLabel.x = Pos.at(0)
        contextLabel.y = Pos.at(0)
        contextLabel.width = Dim.fill()
        win.addSubview(contextLabel)

        let hintLabel = Label(
            "  Plain text = exact match. Prefix with glob: or regex: for advanced matching."
        )
        hintLabel.x = Pos.at(0)
        hintLabel.y = Pos.at(2)
        hintLabel.width = Dim.fill()
        win.addSubview(hintLabel)

        let patternField = TextField("")
        patternField.x = Pos.at(2)
        patternField.y = Pos.at(4)
        patternField.width = Dim.fill(2)
        win.addSubview(patternField)

        let errorLabel = Label("")
        errorLabel.x = Pos.at(2)
        errorLabel.y = Pos.at(6)
        errorLabel.width = Dim.fill(2)
        win.addSubview(errorLabel)

        let recoveryLabel = Label("")
        recoveryLabel.x = Pos.at(2)
        recoveryLabel.y = Pos.at(7)
        recoveryLabel.width = Dim.fill(2)
        win.addSubview(recoveryLabel)

        let footer = Label("  \u{23CE} confirm   Esc cancel")
        footer.x = Pos.at(0)
        footer.y = Pos.at(9)
        footer.width = Dim.fill()
        win.addSubview(footer)

        // If editing, pre-populate
        if let editingIndex, let stages = context.stages[stageName] {
            let rules: [Rule] = switch slot {
            case .pre: stages.preRules ?? []
            case .post: stages.postRules ?? []
            }
            if editingIndex < rules.count {
                patternField.text = rules[editingIndex].match.pattern
            }
        }

        patternField.onSubmit = { [weak self] _ in
            guard let self else { return }
            let pattern = patternField.text.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else {
                errorLabel.text = "  Pattern cannot be empty."
                recoveryLabel.text = ""
                return
            }

            var mutableBuilder = builder
            let result = mutableBuilder.setMatch(field: fieldName, pattern: pattern)
            switch result {
            case .success:
                errorLabel.text = ""
                recoveryLabel.text = ""
                Application.requestStop()
                showEmitActions(
                    fieldName: fieldName,
                    pattern: pattern,
                    builder: mutableBuilder,
                    onComplete: onComplete
                )
            case let .failure(error):
                errorLabel.text = "  \(error.errorDescription ?? "Invalid pattern")"
                recoveryLabel.text = "  \(error.recoverySuggestion ?? "")"
            }
        }

        win.onKey = { event in
            if event.key == .esc {
                Application.requestStop()
                onComplete(nil)
                return true
            }
            return false
        }

        Application.present(top: top)
    }
}
