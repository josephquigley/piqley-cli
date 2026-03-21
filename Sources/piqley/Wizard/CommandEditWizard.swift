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

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
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

        var command = currentBinary?.command ?? ""
        var args = currentBinary?.args ?? []
        var timeout = currentBinary?.timeout
        var fork = currentBinary?.fork ?? false
        var environment = currentBinary?.environment ?? [:]

        var cursor = 0
        var changed = false
        while true {
            let envSummary = environment.isEmpty
                ? "(none)"
                : environment.keys.sorted().joined(separator: ", ")
            let argsSummary = args.isEmpty ? "(none)" : args.joined(separator: " ")
            let timeoutStr = timeout.map { "\($0)s" } ?? "30s (default)"
            let items = [
                "Environment  \(ANSI.dim)\(envSummary)\(ANSI.reset)",
                "Command      \(ANSI.dim)\(command.isEmpty ? "(not set)" : command)\(ANSI.reset)",
                "Arguments    \(ANSI.dim)\(argsSummary)\(ANSI.reset)",
                "Timeout      \(ANSI.dim)\(timeoutStr)\(ANSI.reset)",
                "Fork         \(ANSI.dim)\(fork ? "yes" : "no")\(ANSI.reset)",
            ]

            let hint = "Note: command paths are relative to the plugin directory (not shell PATH)"
            terminal.drawScreen(
                title: "\(stageName) command config\n\(ANSI.dim)\(hint)\(ANSI.reset)",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} edit  Esc done"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                switch cursor {
                case 0: // Environment
                    environment = editEnvironment(stageName: stageName, current: environment)
                    changed = true
                case 1: // Command
                    if let val = terminal.promptForInput(
                        title: "\(stageName): command",
                        hint: "Relative to plugin dir (e.g. ./bin/my-plugin) or absolute path",
                        defaultValue: command.isEmpty ? nil : command,
                        allowEmpty: true
                    ) {
                        command = val
                        changed = true
                    }
                case 2: // Arguments
                    args = editArgs(stageName: stageName, existing: args, envKeys: environment.keys.sorted())
                    changed = true
                case 3: // Timeout
                    let timeoutDefault = timeout.map { String($0) }
                    if let val = terminal.promptForInput(
                        title: "\(stageName): timeout (seconds)",
                        hint: "Default: 30. Press Enter to keep default.",
                        defaultValue: timeoutDefault,
                        allowEmpty: true
                    ) {
                        timeout = val.isEmpty ? nil : Int(val) ?? timeout
                        changed = true
                    }
                case 4: // Fork
                    fork = terminal.confirm("Enable fork (copy-on-write image isolation)?")
                    changed = true
                default: break
                }
            case .escape:
                if changed {
                    let newBinary = HookConfig(
                        command: command.isEmpty ? nil : command,
                        args: args,
                        timeout: timeout,
                        pluginProtocol: currentBinary?.pluginProtocol,
                        successCodes: currentBinary?.successCodes,
                        warningCodes: currentBinary?.warningCodes,
                        criticalCodes: currentBinary?.criticalCodes,
                        batchProxy: currentBinary?.batchProxy,
                        environment: environment.isEmpty ? nil : environment,
                        fork: fork ? true : nil
                    )
                    let newStage = StageConfig(
                        preRules: stage.preRules,
                        binary: newBinary,
                        postRules: stage.postRules
                    )
                    stages[stageName] = newStage
                    modified = true
                }
                return
            default: break
            }
        }
    }

    // MARK: - Args Editor

    private func editArgs(stageName: String, existing: [String], envKeys: [String]) -> [String] {
        var args: [String] = []
        let completions = envKeys.map { "$\($0)" }
        var argIndex = 0
        while true {
            let defaultArg = argIndex < existing.count ? existing[argIndex] : nil
            let ordinal = args.isEmpty ? "first" : "next"
            let hint = args.isEmpty
                ? "e.g. --verbose  or  $MY_VAR"
                : "Enter another arg, or press Enter to finish"
            guard let arg = terminal.promptWithAutocomplete(
                title: "\(stageName): \(ordinal) argument",
                hint: hint,
                completions: completions,
                defaultValue: defaultArg,
                allowEmpty: !args.isEmpty
            ) else {
                break
            }
            if arg.isEmpty { break }
            args.append(arg)
            argIndex += 1
        }
        return args
    }

    // MARK: - Environment Editor

    private func editEnvironment(stageName: String, current: [String: String]?) -> [String: String] {
        var env = current ?? [:]

        if env.isEmpty {
            guard terminal.confirm("\(stageName): Add environment variable mappings?") else {
                return env
            }
        } else {
            // Show existing and offer to edit
            let summary = env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            guard terminal.confirm("\(stageName): Edit environment mappings? (\(summary))") else {
                return env
            }
        }

        var cursor = 0
        while true {
            let entries = env.keys.sorted().map { key in
                "\(key) = \(env[key] ?? "")"
            }
            let items = entries + ["+ Add new variable"]

            terminal.drawScreen(
                title: "\(stageName): environment variables",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} edit  d delete  Esc done"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .enter:
                if cursor == entries.count {
                    // Add new
                    guard let name = terminal.promptForInput(
                        title: "Variable name",
                        hint: "e.g. MY_API_URL"
                    ) else { continue }
                    guard let value = terminal.promptForInput(
                        title: "Value for \(name)",
                        hint: "Use {{namespace:field}} for state template variables"
                    ) else { continue }
                    env[name] = value
                } else {
                    // Edit existing
                    let existingKey = env.keys.sorted()[cursor]
                    guard let value = terminal.promptForInput(
                        title: "Value for \(existingKey)",
                        hint: "Use {{namespace:field}} for state template variables",
                        defaultValue: env[existingKey]
                    ) else { continue }
                    env[existingKey] = value
                }
            case .char("d"):
                if cursor < entries.count {
                    let keyToRemove = env.keys.sorted()[cursor]
                    env.removeValue(forKey: keyToRemove)
                    cursor = min(cursor, max(0, entries.count - 2))
                }
            case .escape:
                return env
            default: break
            }
        }
    }

    // MARK: - Save / Quit

    private func save() {
        do {
            try StageFileManager.saveStages(stages, to: pluginDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    private func quit() {
        StageFileManager.cleanupEmptyStageFiles(stages: stages, pluginDir: pluginDir)
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

    func readKeyWithSaveTimeout() -> Key {
        if let savedAt {
            let remaining = 2.0 - Date().timeIntervalSince(savedAt)
            if remaining > 0 {
                let key = terminal.readKey(timeoutMs: Int32(remaining * 1000))
                if key == .timeout {
                    self.savedAt = nil
                    return .timeout
                }
                return key
            }
            self.savedAt = nil
        }
        return terminal.readKey()
    }
}
