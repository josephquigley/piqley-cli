import Foundation
import PiqleyCore
import TermKit

@MainActor
final class RuleListScreen {
    private var context: RuleEditingContext
    private let stageName: String
    private let onBack: (RuleEditingContext) -> Void
    private var currentSlot: RuleSlot
    private var filterActive = false
    private var filterText = ""
    private var allRuleItems: [(index: Int, display: String)] = []
    private var filteredItems: [(index: Int, display: String)] = []

    init(
        context: RuleEditingContext,
        stageName: String,
        onBack: @escaping (RuleEditingContext) -> Void
    ) {
        self.context = context
        self.stageName = stageName
        self.onBack = onBack
        self.currentSlot = .pre
    }

    func show(in win: WizardWindow) {
        let hasBinary = context.stageHasBinary(stageName)

        clearWindow(win)
        win.title = "\(stageName) rules"

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

        rebuildRuleItems()
        applyFilter()

        let items = filteredItems.isEmpty ? ["(no rules)"] : filteredItems.map(\.display)
        let list = ListView(items: items)
        list.x = Pos.at(1)
        list.y = Pos.at(yOffset)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)
        list.allowMarking = false
        list.selectedMarker = "> "
        win.addSubview(list)

        let footer = Label(
            "  \u{2191}\u{2193} navigate  a add  e edit  d delete  r reorder  q back"
        )
        footer.x = Pos.at(0)
        footer.y = Pos.bottom(of: list) + 1
        footer.width = Dim.fill()
        win.addSubview(footer)

        list.activate = { [weak self] index in
            guard let self, index < self.filteredItems.count else { return true }
            let ruleIndex = self.filteredItems[index].index
            self.editRule(at: ruleIndex, list: list, win: win)
            return true
        }

        win.onKey = { [weak self] event in
            guard let self else { return false }
            return self.handleKey(
                event: event, list: list, slotLabel: slotLabel,
                hasBinary: hasBinary, win: win
            )
        }

        try? win.layoutSubviews()
        _ = list.becomeFirstResponder()
        win.setNeedsDisplay()
    }

    // MARK: - Key handling

    // swiftlint:disable:next function_parameter_count
    private func handleKey(
        event: KeyEvent, list: ListView, slotLabel: Label?,
        hasBinary: Bool, win: WizardWindow
    ) -> Bool {
        switch event.key {
        case .letter("q"), .esc:
            onBack(context)
            return true

        case .letter("a"):
            addRule(list: list, win: win)
            return true

        case .letter("e"):
            let idx = list.selectedItem
            if idx < filteredItems.count {
                editRule(at: filteredItems[idx].index, list: list, win: win)
            }
            return true

        case .letter("d"):
            let idx = list.selectedItem
            if idx < filteredItems.count {
                deleteRule(at: filteredItems[idx].index, list: list, win: win)
            }
            return true

        case .letter("r"):
            let idx = list.selectedItem
            if idx < filteredItems.count {
                moveRuleUp(at: filteredItems[idx].index, list: list, win: win)
            }
            return true

        case .controlI:
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

    // MARK: - Rule data

    private func rebuildRuleItems() {
        let rules = context.rules(forStage: stageName, slot: currentSlot)
        allRuleItems = rules.enumerated().map { index, rule in
            (index: index, display: Self.formatRule(rule, index: index))
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

    private func addRule(list: ListView, win: WizardWindow) {
        let slot = context.stageHasBinary(stageName) ? currentSlot : .pre
        let editor = RuleEditorScreen(context: context, stageName: stageName, slot: slot, editingIndex: nil)
        editor.present { [weak self] rule in
            guard let self, let rule else {
                self?.show(in: win)
                return
            }
            if var stage = self.context.stages[self.stageName] {
                try? stage.appendRule(rule, slot: slot)
                self.context.stages[self.stageName] = stage
            }
            self.show(in: win)
        }
    }

    private func editRule(at index: Int, list: ListView, win: WizardWindow) {
        let slot = context.stageHasBinary(stageName) ? currentSlot : .pre
        let editor = RuleEditorScreen(context: context, stageName: stageName, slot: slot, editingIndex: index)
        editor.present { [weak self] rule in
            guard let self, let rule else {
                self?.show(in: win)
                return
            }
            if var stage = self.context.stages[self.stageName] {
                try? stage.replaceRule(at: index, with: rule, slot: slot)
                self.context.stages[self.stageName] = stage
            }
            self.show(in: win)
        }
    }

    private func deleteRule(at index: Int, list: ListView, win: WizardWindow) {
        let slot = context.stageHasBinary(stageName) ? currentSlot : .pre
        if var stage = context.stages[stageName] {
            try? stage.removeRule(at: index, slot: slot)
            context.stages[stageName] = stage
        }
        rebuildRuleItems()
        applyFilter()
        refreshList(list)
    }

    private func moveRuleUp(at index: Int, list: ListView, win: WizardWindow) {
        let slot = context.stageHasBinary(stageName) ? currentSlot : .pre
        let rules = context.rules(forStage: stageName, slot: slot)
        guard rules.count > 1, index < rules.count, index > 0 else { return }
        if var stage = context.stages[stageName] {
            try? stage.moveRule(from: index, to: index - 1, slot: slot)
            context.stages[stageName] = stage
        }
        rebuildRuleItems()
        applyFilter()
        refreshList(list)
    }
}
