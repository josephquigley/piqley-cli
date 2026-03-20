import Foundation
import PiqleyCore
import TermKit

@MainActor
final class StageSelectScreen {
    private var context: RuleEditingContext
    private let writeBack: RulesWizardApp.WriteBackConfig
    private var modified = false

    init(context: RuleEditingContext, writeBack: RulesWizardApp.WriteBackConfig) {
        self.context = context
        self.writeBack = writeBack
    }

    func show(in win: WizardWindow) {
        let stageNames = context.stageNames()
        guard !stageNames.isEmpty else {
            print("No stages found for plugin '\(context.pluginIdentifier)'.")
            exit(1)
        }

        // Clear previous content
        clearWindow(win)
        win.title = "Edit Rules: \(context.pluginIdentifier)"

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
            self.openRuleList(for: stageNames[index], win: win, list: list, stageNames: stageNames)
            return true
        }

        win.onKey = { [weak self] event in
            guard let self else { return false }
            switch event.key {
            case .letter("q"):
                self.quitWizard()
                return true
            case .letter("s"):
                self.saveAndQuit()
                return true
            default:
                return false
            }
        }

        try? win.layoutSubviews()
        _ = list.becomeFirstResponder()
        win.setNeedsDisplay()
    }

    private func openRuleList(for stageName: String, win: WizardWindow, list: ListView, stageNames: [String]) {
        let ruleListScreen = RuleListScreen(
            context: context,
            stageName: stageName
        ) { [weak self] updatedContext in
            guard let self else { return }
            self.context = updatedContext
            self.modified = true
            // Re-show stage select when returning
            self.show(in: win)
        }
        ruleListScreen.show(in: win)
    }

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

    private func saveAndQuit() {
        do {
            try RulesWizardApp.saveStages(context.stages, to: writeBack.pluginDir)
        } catch {
            FileHandle.standardError.write(Data("Error saving: \(error.localizedDescription)\n".utf8))
        }
        RulesWizardApp.exitWizard()
    }

    private func quitWizard() {
        if modified {
            saveAndQuit()
        } else {
            RulesWizardApp.exitWizard()
        }
    }
}

/// Helper to clear all child views from a window.
func clearWindow(_ win: Window) {
    for view in win.subviews {
        win.removeSubview(view)
    }
}
