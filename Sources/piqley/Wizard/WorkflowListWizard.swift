import Foundation
import PiqleyCore

final class WorkflowListWizard {
    let discoveredPlugins: [LoadedPlugin]
    let registry: StageRegistry
    let terminal: RawTerminal

    init(discoveredPlugins: [LoadedPlugin], registry: StageRegistry) {
        self.discoveredPlugins = discoveredPlugins
        self.registry = registry
        terminal = RawTerminal()
    }

    func run() {
        defer { terminal.restore() }
        workflowList()
    }

    // MARK: - Workflow List

    private func workflowList() {
        var cursor = 0

        while true {
            let workflows: [String]
            do {
                workflows = try WorkflowStore.list()
            } catch {
                terminal.showMessage("Error loading workflows: \(error)")
                return
            }

            let items = workflows.isEmpty ? ["(no workflows)"] : workflows

            drawWorkflowListScreen(items: items, cursor: cursor, isEmpty: workflows.isEmpty)

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(max(items.count - 1, 0), cursor + 1)
            case .enter:
                if !workflows.isEmpty, cursor < workflows.count {
                    editWorkflow(name: workflows[cursor])
                }
            case .char("n"):
                newWorkflow()
            case .char("d"):
                if !workflows.isEmpty, cursor < workflows.count {
                    deleteWorkflow(name: workflows[cursor])
                    cursor = min(cursor, max(0, workflows.count - 2))
                }
            case .char("c"):
                if !workflows.isEmpty, cursor < workflows.count {
                    cloneWorkflow(name: workflows[cursor])
                }
            case .escape, .ctrlC:
                return
            default: break
            }
        }
    }

    private func drawWorkflowListScreen(items: [String], cursor: Int, isEmpty: Bool) {
        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)Workflows\(ANSI.reset)"

        for (idx, item) in items.enumerated() {
            buf += ANSI.moveTo(row: 3 + idx, col: 1)
            if idx == cursor, !isEmpty {
                buf += "\(ANSI.inverse) \u{25B8} \(item) \(ANSI.reset)"
            } else {
                buf += "   \(item)"
            }
        }

        buf += ANSI.moveTo(row: size.rows, col: 1)
        var footer = "\u{2191}\u{2193} navigate  n new"
        if !isEmpty {
            footer += "  \u{23CE} edit  d delete  c clone"
        }
        footer += "  Esc quit"
        buf += "\(ANSI.dim)\(footer)\(ANSI.reset)"

        terminal.write(buf)
    }

    // MARK: - Actions

    private func editWorkflow(name: String) {
        do {
            let workflow = try WorkflowStore.load(name: name)
            // Temporarily restore terminal for nested wizard
            terminal.restore()
            let wizard = ConfigWizard(workflow: workflow, discoveredPlugins: discoveredPlugins, registry: registry)
            wizard.run()
            // Re-enter raw mode
            terminal.reenter()
        } catch {
            terminal.showMessage("Error loading workflow '\(name)': \(error)")
        }
    }

    private func newWorkflow() {
        guard let name = terminal.promptForInput(
            title: "New Workflow",
            hint: "Enter a name for the new workflow"
        ) else { return }

        if WorkflowStore.exists(name: name) {
            terminal.showMessage("Workflow '\(name)' already exists.")
            return
        }

        let workflow = Workflow.empty(name: name, displayName: name, activeStages: registry.executionOrder)
        do {
            try WorkflowStore.save(workflow)
        } catch {
            terminal.showMessage("Error creating workflow: \(error)")
            return
        }

        editWorkflow(name: name)
    }

    private func deleteWorkflow(name: String) {
        guard terminal.confirm("Delete workflow '\(name)'?") else { return }
        do {
            try WorkflowStore.delete(name: name)
        } catch {
            terminal.showMessage("Error deleting workflow: \(error)")
        }
    }

    private func cloneWorkflow(name: String) {
        guard let destination = terminal.promptForInput(
            title: "Clone '\(name)'",
            hint: "Enter a name for the cloned workflow"
        ) else { return }

        do {
            try WorkflowStore.clone(source: name, destination: destination)
        } catch {
            terminal.showMessage("Error cloning workflow: \(error)")
        }
    }
}
