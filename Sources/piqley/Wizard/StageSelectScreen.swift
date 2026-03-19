import PiqleyCore
import TermKit

/// Screen: select which stage to edit rules for.
/// Shows stage names with rule counts.
@MainActor
final class StageSelectScreen {
    private var context: RuleEditingContext
    private let writeBack: RulesWizardApp.WriteBackConfig
    private var modified = false

    init(context: RuleEditingContext, writeBack: RulesWizardApp.WriteBackConfig) {
        self.context = context
        self.writeBack = writeBack
    }

    func present() {
        let stageNames = context.stageNames()
        guard !stageNames.isEmpty else {
            print("No stages found for plugin '\(context.pluginIdentifier)'.")
            Application.shutdown()
            return
        }

        let win = WizardWindow("Edit Rules: \(context.pluginIdentifier)")
        win.fill()
        Application.top.addSubview(win)

        let list = ListView(items: buildStageItems(stageNames))
        list.x = Pos.at(1)
        list.y = Pos.at(1)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)
        list.allowMarking = false
        list.selectedMarker = "> "
        win.addSubview(list)

        let footer = Label("  \u{2191}\u{2193} navigate   \u{23CE} select   s save & quit   q quit")
        footer.x = Pos.at(0)
        footer.y = Pos.bottom(of: list) + 1
        footer.width = Dim.fill()
        win.addSubview(footer)

        list.activate = { [weak self] index in
            guard let self, index < stageNames.count else { return true }
            openRuleList(for: stageNames[index], list: list, stageNames: stageNames)
            return true
        }

        win.onKey = { [weak self] event in
            guard let self else { return false }
            switch event.key {
            case .letter("q"):
                if modified {
                    confirmQuit()
                } else {
                    Application.shutdown()
                }
                return true
            case .letter("s"):
                saveAndQuit()
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Navigation

    private func openRuleList(for stageName: String, list: ListView, stageNames: [String]) {
        let ruleListScreen = RuleListScreen(
            context: context,
            stageName: stageName
        ) { [weak self] updatedContext in
            guard let self else { return }
            context = updatedContext
            modified = true
            list.items = buildStageItems(stageNames)
            list.setNeedsDisplay()
        }
        ruleListScreen.present()
    }

    // MARK: - Display helpers

    private func buildStageItems(_ stageNames: [String]) -> [String] {
        stageNames.map { name in
            let preCount = context.rules(forStage: name, slot: .pre).count
            let postCount = context.rules(forStage: name, slot: .post).count
            let total = preCount + postCount
            let hasBinary = context.stageHasBinary(name)
            if hasBinary {
                return "\(name) (\(total) rules: \(preCount) pre, \(postCount) post)"
            } else {
                return "\(name) (\(total) rules)"
            }
        }
    }

    // MARK: - Save / Quit

    private func saveAndQuit() {
        do {
            try RulesWizardApp.saveStages(context.stages, to: writeBack.pluginDir)
            Application.shutdown()
        } catch {
            // Show error in a simple dialog
            let alert = Dialog(title: "Save Error", width: 60, height: 8, buttons: [
                Button("OK") { Application.requestStop() },
            ])
            let msg = Label(error.localizedDescription)
            msg.x = Pos.at(1)
            msg.y = Pos.at(1)
            msg.width = Dim.fill(1)
            alert.addSubview(msg)
            Application.present(top: alert)
        }
    }

    private func confirmQuit() {
        let dialog = Dialog(title: "Unsaved Changes", width: 50, height: 7, buttons: [
            Button("Quit without saving") { Application.shutdown() },
            Button("Cancel") { Application.requestStop() },
        ])
        let msg = Label("You have unsaved changes. Quit anyway?")
        msg.x = Pos.at(1)
        msg.y = Pos.at(1)
        msg.width = Dim.fill(1)
        dialog.addSubview(msg)
        Application.present(top: dialog)
    }
}
