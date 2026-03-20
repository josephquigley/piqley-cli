import PiqleyCore
import TermKit

/// Screen: list rules for a stage with filtering and action keys.
@MainActor
final class RuleListScreen {
    private var context: RuleEditingContext
    private let stageName: String
    private let onUpdate: (RuleEditingContext) -> Void

    /// The currently active slot (pre or post). For stages without a binary, always .pre.
    private var currentSlot: RuleSlot

    /// Whether the filter text field is active.
    private var filterActive = false
    private var filterText = ""

    /// All rule display items (unfiltered).
    private var allRuleItems: [(index: Int, display: String)] = []

    /// Filtered items currently shown in the list.
    private var filteredItems: [(index: Int, display: String)] = []

    init(
        context: RuleEditingContext,
        stageName: String,
        onUpdate: @escaping (RuleEditingContext) -> Void
    ) {
        self.context = context
        self.stageName = stageName
        self.onUpdate = onUpdate
        currentSlot = .pre
    }

    func present() {
        let hasBinary = context.stageHasBinary(stageName)

        let top = Toplevel()
        top.fill()
        if let scheme = RulesWizardApp.wizardColorScheme {
            top.colorScheme = scheme
        }

        let win = WizardWindow("\(stageName) rules")
        win.fill()
        top.addSubview(win)

        // Slot indicator (only if binary exists)
        var yOffset = 0
        var slotLabel: Label?
        if hasBinary {
            let slotLbl = Label("Slot: [pre] post   (Tab to switch)")
            slotLbl.x = Pos.at(1)
            slotLbl.y = Pos.at(0)
            slotLbl.width = Dim.fill(1)
            win.addSubview(slotLbl)
            slotLabel = slotLbl
            yOffset = 1
        }

        // Filter field (always present but starts unfocused)
        let filterLabel = Label("  Filter: ")
        filterLabel.x = Pos.at(0)
        filterLabel.y = Pos.at(yOffset)
        win.addSubview(filterLabel)

        let filterField = TextField("")
        filterField.x = Pos.at(10)
        filterField.y = Pos.at(yOffset)
        filterField.width = Dim.fill(1)
        filterField.canFocus = false
        win.addSubview(filterField)

        let listYOffset = yOffset + 1

        // Rule list
        rebuildRuleItems()
        applyFilter()

        let emptyMsg = filteredItems.isEmpty ? ["(no rules)"] : filteredItems.map(\.display)
        let list = ListView(items: emptyMsg)
        list.x = Pos.at(1)
        list.y = Pos.at(listYOffset)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)
        list.allowMarking = false
        list.selectedMarker = "> "
        win.addSubview(list)

        // Footer
        let footer = Label(
            "  \u{2191}\u{2193} navigate   a add   e edit   d delete   r reorder   f filter   q back"
        )
        footer.x = Pos.at(0)
        footer.y = Pos.bottom(of: list) + 1
        footer.width = Dim.fill()
        win.addSubview(footer)

        // Key handling — WizardWindow.onKey intercepts before the focused view.
        // Also handle on the Toplevel level via processColdKey for keys that
        // the focused ListView doesn't consume.
        let views = ListViews(list: list, filterField: filterField, slotLabel: slotLabel, hasBinary: hasBinary)
        win.onKey = { [weak self] event in
            guard let self else { return false }
            return handleKey(event: event, views: views)
        }

        // Filter text changes
        filterField.textChanged = { [weak self] _, _ in
            guard let self else { return }
            filterText = filterField.text
            applyFilter()
            refreshList(list)
        }

        // Edit on Enter
        list.activate = { [weak self] index in
            guard let self, index < filteredItems.count else { return true }
            let ruleIndex = filteredItems[index].index
            editRule(at: ruleIndex, list: list)
            return true
        }

        _ = list.becomeFirstResponder()
        Application.present(top: top)
    }

    // MARK: - Key handling

    private struct ListViews {
        let list: ListView
        let filterField: TextField
        let slotLabel: Label?
        let hasBinary: Bool
    }

    private func handleKey(event: KeyEvent, views: ListViews) -> Bool {
        let list = views.list
        let filterField = views.filterField
        let slotLabel = views.slotLabel
        let hasBinary = views.hasBinary
        // If filter is active, handle Esc to close filter
        if filterActive {
            if event.key == .esc {
                deactivateFilter(filterField: filterField, list: list)
                return true
            }
            return false // let the TextField handle normal typing
        }

        switch event.key {
        case .letter("q"), .esc:
            onUpdate(context)
            Application.requestStop()
            return true

        case .letter("a"):
            addRule(list: list)
            return true

        case .letter("e"):
            let selectedIdx = list.selectedItem
            if selectedIdx < filteredItems.count {
                let ruleIndex = filteredItems[selectedIdx].index
                editRule(at: ruleIndex, list: list)
            }
            return true

        case .letter("d"):
            let selectedIdx = list.selectedItem
            if selectedIdx < filteredItems.count {
                let ruleIndex = filteredItems[selectedIdx].index
                deleteRule(at: ruleIndex, list: list)
            }
            return true

        case .letter("r"):
            let selectedIdx = list.selectedItem
            if selectedIdx < filteredItems.count {
                let ruleIndex = filteredItems[selectedIdx].index
                startReorder(from: ruleIndex, list: list)
            }
            return true

        case .letter("f"):
            activateFilter(filterField: filterField, list: list)
            return true

        case .controlI: // Tab
            if hasBinary {
                currentSlot = (currentSlot == .pre) ? .post : .pre
                slotLabel?.text = currentSlot == .pre
                    ? "Slot: [pre] post   (Tab to switch)"
                    : "Slot: pre [post]   (Tab to switch)"
                rebuildRuleItems()
                applyFilter()
                refreshList(list)
                return true
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Filter

    private func activateFilter(filterField: TextField, list _: ListView) {
        filterActive = true
        filterField.canFocus = true
        filterField.text = filterText
        _ = filterField.becomeFirstResponder()
    }

    private func deactivateFilter(filterField: TextField, list: ListView) {
        filterActive = false
        filterText = ""
        filterField.text = ""
        filterField.canFocus = false
        applyFilter()
        refreshList(list)
        _ = list.becomeFirstResponder()
    }

    // MARK: - Rule data

    private func rebuildRuleItems() {
        let rules = context.rules(forStage: stageName, slot: currentSlot)
        allRuleItems = rules.enumerated().map { index, rule in
            let display = Self.formatRule(rule, index: index)
            return (index: index, display: display)
        }
    }

    private func applyFilter() {
        if filterText.isEmpty {
            filteredItems = allRuleItems
        } else {
            let query = filterText.lowercased()
            filteredItems = allRuleItems.filter { $0.display.lowercased().contains(query) }
        }
    }

    private func refreshList(_ list: ListView) {
        let items = filteredItems.isEmpty ? ["(no rules)"] : filteredItems.map(\.display)
        list.items = items
        list.setNeedsDisplay()
    }

    static func formatRule(_ rule: Rule, index: Int) -> String {
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

    // MARK: - Actions

    private func addRule(list: ListView) {
        let hasBinary = context.stageHasBinary(stageName)
        let slot = hasBinary ? currentSlot : .pre

        let editor = RuleEditorScreen(context: context, stageName: stageName, slot: slot, editingIndex: nil)
        editor.present { [weak self] rule in
            guard let self, let rule else { return }
            if var stage = context.stages[stageName] {
                try? stage.appendRule(rule, slot: slot)
                context.stages[stageName] = stage
            }
            onUpdate(context)
            rebuildRuleItems()
            applyFilter()
            refreshList(list)
        }
    }

    private func editRule(at index: Int, list: ListView) {
        let hasBinary = context.stageHasBinary(stageName)
        let slot = hasBinary ? currentSlot : .pre

        let editor = RuleEditorScreen(context: context, stageName: stageName, slot: slot, editingIndex: index)
        editor.present { [weak self] rule in
            guard let self, let rule else { return }
            if var stage = context.stages[stageName] {
                try? stage.replaceRule(at: index, with: rule, slot: slot)
                context.stages[stageName] = stage
            }
            onUpdate(context)
            rebuildRuleItems()
            applyFilter()
            refreshList(list)
        }
    }

    private func deleteRule(at index: Int, list: ListView) {
        let hasBinary = context.stageHasBinary(stageName)
        let slot = hasBinary ? currentSlot : .pre

        let rules = context.rules(forStage: stageName, slot: slot)
        guard index < rules.count else { return }
        let rule = rules[index]

        let dialog = Dialog(title: "Delete Rule?", width: 60, height: 10, buttons: [
            Button("Delete") { [weak self] in
                guard let self else { return }
                if var stage = context.stages[stageName] {
                    try? stage.removeRule(at: index, slot: slot)
                    context.stages[stageName] = stage
                }
                onUpdate(context)
                rebuildRuleItems()
                applyFilter()
                refreshList(list)
                Application.requestStop()
            },
            Button("Cancel") { Application.requestStop() },
        ])
        let msg = Label(Self.formatRule(rule, index: index))
        msg.x = Pos.at(1)
        msg.y = Pos.at(1)
        msg.width = Dim.fill(1)
        dialog.addSubview(msg)
        Application.present(top: dialog)
    }

    private func startReorder(from index: Int, list: ListView) {
        let hasBinary = context.stageHasBinary(stageName)
        let slot = hasBinary ? currentSlot : .pre
        let rules = context.rules(forStage: stageName, slot: slot)
        guard rules.count > 1, index < rules.count else { return }

        let dialog = Dialog(title: "Reorder Rule \(index + 1)", width: 40, height: 8, buttons: [
            Button("Move Up") { [weak self] in
                guard let self, index > 0 else { Application.requestStop(); return }
                if var stage = context.stages[stageName] {
                    try? stage.moveRule(from: index, to: index - 1, slot: slot)
                    context.stages[stageName] = stage
                }
                onUpdate(context)
                rebuildRuleItems()
                applyFilter()
                refreshList(list)
                Application.requestStop()
            },
            Button("Move Down") { [weak self] in
                guard let self, index < rules.count - 1 else { Application.requestStop(); return }
                if var stage = context.stages[stageName] {
                    try? stage.moveRule(from: index, to: index + 1, slot: slot)
                    context.stages[stageName] = stage
                }
                onUpdate(context)
                rebuildRuleItems()
                applyFilter()
                refreshList(list)
                Application.requestStop()
            },
            Button("Cancel") { Application.requestStop() },
        ])
        let msg = Label("Move rule \(index + 1) of \(rules.count)")
        msg.x = Pos.at(1)
        msg.y = Pos.at(1)
        msg.width = Dim.fill(1)
        dialog.addSubview(msg)
        Application.present(top: dialog)
    }
}
