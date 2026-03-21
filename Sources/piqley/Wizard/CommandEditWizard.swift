import Foundation
import PiqleyCore

final class CommandEditWizard {
    let pluginID: String
    var stages: [String: StageConfig]
    let pluginDir: URL
    let terminal: RawTerminal
    var modified = false
    var savedAt: Date?

    /// Field completions for env var editor: display name -> (envVarName, templateValue)
    let fieldCompletions: [EnvFieldCompletion]

    struct EnvFieldCompletion {
        /// What the user types/searches: e.g. "IPTC:Keywords"
        let displayName: String
        /// Suggested env var name: e.g. "PQY_IPTC_KEYWORDS"
        let envVarName: String
        /// Template value: e.g. "{{original:IPTC:Keywords}}"
        let templateValue: String
    }

    init(
        pluginID: String, stages: [String: StageConfig], pluginDir: URL,
        availableFields: [String: [FieldInfo]] = [:]
    ) {
        self.pluginID = pluginID
        self.stages = stages
        self.pluginDir = pluginDir
        terminal = RawTerminal()
        fieldCompletions = Self.buildFieldCompletions(from: availableFields)
    }

    private static func buildFieldCompletions(from fields: [String: [FieldInfo]]) -> [EnvFieldCompletion] {
        var seen = Set<String>()
        var result: [EnvFieldCompletion] = []
        for (_, fieldInfos) in fields.sorted(by: { $0.key < $1.key }) {
            for field in fieldInfos {
                guard !seen.contains(field.qualifiedName) else { continue }
                seen.insert(field.qualifiedName)
                let envName = fieldToEnvVar(field.name)
                result.append(EnvFieldCompletion(
                    displayName: field.name,
                    envVarName: envName,
                    templateValue: "{{\(field.qualifiedName)}}"
                ))
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    /// Convert "IPTC:Keywords" -> "PQY_IPTC_KEYWORDS"
    private static func fieldToEnvVar(_ fieldName: String) -> String {
        let parts = fieldName.split(separator: ":")
        let transformed = parts.map { part in
            // Split PascalCase/camelCase into words, join with _
            var words: [String] = []
            var current = ""
            for char in part {
                if char.isUppercase, !current.isEmpty {
                    words.append(current.uppercased())
                    current = String(char)
                } else {
                    current.append(char)
                }
            }
            if !current.isEmpty { words.append(current.uppercased()) }
            return words.joined(separator: "_")
        }
        return "PQY_\(transformed.joined(separator: "_"))"
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
                "Environment Variables  \(ANSI.dim)\(envSummary)\(ANSI.reset)",
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
                    // Add new — autocomplete from available fields
                    // Display: "IPTC:Keywords -> $PQY_IPTC_KEYWORDS", Tab inserts "PQY_IPTC_KEYWORDS"
                    let displayCompletions = fieldCompletions.map {
                        "\($0.displayName) \u{2192} $\($0.envVarName)"
                    }
                    let insertCompletions = fieldCompletions.map(\.envVarName)

                    guard let input = terminal.promptWithAutocomplete(
                        title: "Variable name",
                        hint: "Type to search fields (Tab to insert mapped name), or enter a custom name",
                        completions: displayCompletions,
                        insertCompletions: insertCompletions
                    ) else { continue }

                    // Check if the input matches a known env var name
                    if let match = fieldCompletions.first(where: { $0.envVarName == input }) {
                        // Pre-fill template value
                        let templateCompletions = fieldCompletions.map(\.templateValue)
                        if let value = terminal.promptWithAutocomplete(
                            title: "Value for \(input)",
                            hint: "Press Enter to accept pre-filled template",
                            completions: templateCompletions,
                            defaultValue: match.templateValue
                        ) {
                            env[input] = value
                        }
                    } else {
                        // Custom variable name — no pre-fill
                        let templateCompletions = fieldCompletions.map(\.templateValue)
                        if let value = terminal.promptWithAutocomplete(
                            title: "Value for \(input)",
                            hint: "Use {{namespace:field}} for state templates",
                            completions: templateCompletions
                        ) {
                            env[input] = value
                        }
                    }
                } else {
                    // Edit existing value
                    let existingKey = env.keys.sorted()[cursor]
                    let templateCompletions = fieldCompletions.map(\.templateValue)
                    guard let value = terminal.promptWithAutocomplete(
                        title: "Value for \(existingKey)",
                        hint: "Use {{namespace:field}} for state template variables",
                        completions: templateCompletions,
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
