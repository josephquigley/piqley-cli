import Foundation
import PiqleyCore

final class CommandEditWizard {
    let pluginID: String
    var stages: [String: StageConfig]
    let pluginDir: URL
    let terminal: RawTerminal
    var modified = false
    var savedAt: Date?

    init(pluginID: String, stages: [String: StageConfig], pluginDir: URL) {
        self.pluginID = pluginID
        self.stages = stages
        self.pluginDir = pluginDir
        terminal = RawTerminal()
    }

    func run() throws {
        defer { terminal.restore() }
        stageSelect()
    }

    // MARK: - Stage Select

    private func stageSelect() {
        let stageNames = Hook.canonicalOrder.map(\.rawValue).filter { stages.keys.contains($0) }
        guard !stageNames.isEmpty else {
            terminal.restore()
            print("No stages found for plugin '\(pluginID)'.")
            return
        }

        var cursor = 0
        while true {
            let items = stageNames.map { name in
                let binary = stages[name]?.binary
                if let command = binary?.command, !command.isEmpty {
                    let args = binary?.args ?? []
                    let argsStr = args.isEmpty ? "" : " \(args.joined(separator: " "))"
                    return "\(name): \(command)\(argsStr)"
                }
                return "\(name): (no command)"
            }

            terminal.drawScreen(
                title: "Edit Commands: \(pluginID)",
                items: items,
                cursor: cursor,
                footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  \u{23CE} edit  s save  Esc quit")
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                editCommand(stageName: stageNames[cursor])
            case .char("s"):
                save()
            case .escape, .ctrlC:
                promptUnsavedAndExit()
            default: break
            }
        }
    }

    // MARK: - Edit Command

    private func editCommand(stageName: String) {
        guard let stage = stages[stageName] else { return }
        let currentBinary = stage.binary

        // Prompt for command
        guard let command = terminal.promptForInput(
            title: "\(stageName): binary command",
            hint: "Path to executable (e.g. ./bin/my-plugin)",
            defaultValue: currentBinary?.command,
            allowEmpty: true
        ) else { return }

        // Prompt for args one at a time
        var args: [String] = []
        let existingArgs = currentBinary?.args ?? []
        var argIndex = 0
        while true {
            let defaultArg = argIndex < existingArgs.count ? existingArgs[argIndex] : nil
            let ordinal = args.isEmpty ? "first" : "next"
            let hint = args.isEmpty
                ? "e.g. --verbose  (Enter to skip args)"
                : "Enter another arg, or press Enter to finish"
            guard let arg = terminal.promptForInput(
                title: "\(stageName): \(ordinal) argument",
                hint: hint,
                defaultValue: defaultArg,
                allowEmpty: !args.isEmpty
            ) else {
                if args.isEmpty { break }
                break
            }
            if arg.isEmpty { break }
            args.append(arg)
            argIndex += 1
        }

        // Prompt for timeout
        let currentTimeout = currentBinary?.timeout
        let timeoutDefault = currentTimeout.map { String($0) }
        let timeoutStr = terminal.promptForInput(
            title: "\(stageName): timeout (seconds)",
            hint: "Default: 30. Press Enter to keep default.",
            defaultValue: timeoutDefault,
            allowEmpty: true
        )
        let timeout: Int? = timeoutStr.flatMap { $0.isEmpty ? nil : Int($0) } ?? currentTimeout

        // Prompt for fork
        let currentFork = currentBinary?.fork ?? false
        let fork = terminal.confirm("Enable fork (copy-on-write image isolation)?")

        // Build new HookConfig
        let newBinary = HookConfig(
            command: command.isEmpty ? nil : command,
            args: args,
            timeout: timeout,
            pluginProtocol: currentBinary?.pluginProtocol,
            successCodes: currentBinary?.successCodes,
            warningCodes: currentBinary?.warningCodes,
            criticalCodes: currentBinary?.criticalCodes,
            batchProxy: currentBinary?.batchProxy,
            environment: currentBinary?.environment,
            fork: fork ? true : nil
        )

        // Reconstruct StageConfig (binary is let)
        let newStage = StageConfig(
            preRules: stage.preRules,
            binary: newBinary,
            postRules: stage.postRules
        )
        stages[stageName] = newStage
        modified = true
    }

    // MARK: - Save / Quit

    private func save() {
        do {
            try RulesWizard.saveStages(stages, to: pluginDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    private func quit() {
        terminal.restore()
        Foundation.exit(0)
    }

    private func promptUnsavedAndExit() {
        if !modified { quit() }

        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)You have unsaved changes.\(ANSI.reset)"
        buf += ANSI.moveTo(row: 3, col: 1)
        buf += "  s  Save and quit"
        buf += ANSI.moveTo(row: 4, col: 1)
        buf += "  d  Discard and quit"
        buf += ANSI.moveTo(row: 5, col: 1)
        buf += "  Esc  Cancel (go back)"
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)s save  d discard  Esc cancel\(ANSI.reset)"
        terminal.write(buf)

        while true {
            let key = terminal.readKey()
            switch key {
            case .char("s"):
                save()
                quit()
            case .char("d"):
                quit()
            case .escape:
                return
            default: break
            }
        }
    }

    func footerWithSaveIndicator(_ base: String) -> String {
        if let savedAt, Date().timeIntervalSince(savedAt) < 2 {
            return "\(ANSI.green)\(ANSI.bold)Saved\(ANSI.reset)  \(base)"
        }
        return base
    }
}
