// swiftlint:disable file_length
import Foundation
import PiqleyCore

// swiftlint:disable:next type_body_length
final class CommandEditWizard {
    let pluginID: String
    var stages: [String: StageConfig]
    let pluginDir: URL
    let rulesDir: URL
    let terminal: RawTerminal
    var modified = false
    var savedAt: Date?

    /// Field completions for env var editor: display name -> (envVarName, templateValue)
    let fieldCompletions: [EnvFieldCompletion]

    // swiftlint:disable:next line_length
    private static let envValueHint = "Wrap field names in {{ and }} to use their values. You can use literals, variables, or a mix (e.g. https://{{original:IPTC:City}}.example.com)"

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
        rulesDir: URL,
        availableFields: [String: [FieldInfo]] = [:]
    ) {
        self.pluginID = pluginID
        self.stages = stages
        self.pluginDir = pluginDir
        self.rulesDir = rulesDir
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
    /// Namespace (before :) is uppercased as-is. Field name (after :) splits PascalCase.
    private static func fieldToEnvVar(_ fieldName: String) -> String {
        let parts = fieldName.split(separator: ":", maxSplits: 1)
        let transformed = parts.enumerated().map { index, part in
            if index == 0 {
                // Namespace: uppercase as-is, no PascalCase splitting
                return String(part).uppercased()
            }
            // Field name: split PascalCase/camelCase into words, join with _
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
        let stageNames = stages.keys.sorted()
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

    private struct CommandState {
        var command: String
        var args: [String]
        var timeout: Int?
        var environment: [String: String]
        var pluginProtocol: PluginProtocol?
        var batchProxy: BatchProxyConfig?
        var changed = false

        init(from binary: HookConfig?) {
            command = binary?.command ?? ""
            args = binary?.args ?? []
            timeout = binary?.timeout
            environment = binary?.environment ?? [:]
            pluginProtocol = binary?.pluginProtocol
            batchProxy = binary?.batchProxy
        }

        func toHookConfig(preserving original: HookConfig?) -> HookConfig {
            HookConfig(
                command: command.isEmpty ? nil : command,
                args: args, timeout: timeout,
                pluginProtocol: pluginProtocol,
                successCodes: original?.successCodes,
                warningCodes: original?.warningCodes,
                criticalCodes: original?.criticalCodes,
                batchProxy: batchProxy,
                environment: environment.isEmpty ? nil : environment
            )
        }
    }

    private func editCommand(stageName: String) {
        guard let stage = stages[stageName] else { return }
        var state = CommandState(from: stage.binary)

        var cursor = 0
        while true {
            let items = commandFieldItems(state)

            let hint = "Note: command paths are relative to the plugin directory (not shell PATH)"
            terminal.drawScreen(
                title: "\(stageName) command config\n\(ANSI.dim)\(hint)\(ANSI.reset)",
                items: items,
                cursor: cursor,
                footer: footerWithSaveIndicator(
                    "\u{2191}\u{2193} navigate  \u{23CE} edit  d delete  s save  Esc done")
            )

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .char("d"):
                if terminal.confirm("Delete command for \(stageName)?") {
                    stages[stageName] = StageConfig(
                        preRules: stage.preRules, binary: nil, postRules: stage.postRules
                    )
                    modified = true
                    return
                }
            case .char("s"):
                if state.changed {
                    applyCommandState(stageName: stageName, stage: stage, state: &state)
                }
                save()
            case .enter:
                editCommandField(cursor: cursor, stageName: stageName, state: &state)
            case .escape:
                if state.changed {
                    applyCommandState(stageName: stageName, stage: stage, state: &state)
                }
                return
            default: break
            }
        }
    }

    private func commandFieldItems(_ state: CommandState) -> [String] {
        let envSummary = state.environment.isEmpty
            ? "(none)"
            : state.environment.keys.sorted().joined(separator: ", ")
        let argsSummary = state.args.isEmpty ? "(none)" : state.args.joined(separator: " ")
        let timeoutStr = state.timeout.map { "\($0)s" } ?? "30s (default)"
        return [
            "Environment Variables  \(ANSI.dim)\(envSummary)\(ANSI.reset)",
            "Command      \(ANSI.dim)\(state.command.isEmpty ? "(not set)" : state.command)\(ANSI.reset)",
            "Arguments    \(ANSI.dim)\(argsSummary)\(ANSI.reset)",
            "Timeout      \(ANSI.dim)\(timeoutStr)\(ANSI.reset)",
        ]
    }

    private func applyCommandState(stageName: String, stage: StageConfig, state: inout CommandState) {
        let newBinary = state.toHookConfig(preserving: stage.binary)
        stages[stageName] = StageConfig(
            preRules: stage.preRules, binary: newBinary, postRules: stage.postRules
        )
        modified = true
        state.changed = false
    }

    private func editCommandField(cursor: Int, stageName: String, state: inout CommandState) {
        switch cursor {
        case 0: // Environment
            state.environment = editEnvironment(stageName: stageName, current: state.environment)
            state.changed = true
        case 1: // Command
            editCommandBinary(stageName: stageName, state: &state)
        case 2: // Arguments
            state.args = editArgs(
                stageName: stageName, existing: state.args,
                envKeys: state.environment.keys.sorted()
            )
            state.changed = true
        case 3: // Timeout
            let timeoutDefault = state.timeout.map { String($0) }
            if let val = terminal.promptForInput(
                title: "\(stageName): timeout (seconds)",
                hint: "Default: 30. Press Enter to keep default.",
                defaultValue: timeoutDefault,
                allowEmpty: true
            ) {
                state.timeout = val.isEmpty ? nil : Int(val) ?? state.timeout
                state.changed = true
            }
        default: break
        }
    }

    private func editCommandBinary(stageName: String, state: inout CommandState) {
        guard let val = terminal.promptForInput(
            title: "\(stageName): command",
            hint: "Relative to plugin dir (e.g. ./bin/my-plugin) or absolute path",
            defaultValue: state.command.isEmpty ? nil : state.command,
            allowEmpty: true
        ) else { return }

        if val.isEmpty {
            state.command = val
            state.changed = true
            return
        }

        let probeResult = BinaryProbe.probe(command: val, pluginDirectory: pluginDir)
        switch probeResult {
        case .notFound:
            let resolved = BinaryProbe.resolveExecutable(val, pluginDirectory: pluginDir)
            terminal.showMessage("Command not found at \(resolved)")
        case .notExecutable:
            let resolved = BinaryProbe.resolveExecutable(val, pluginDirectory: pluginDir)
            terminal.showMessage("Command exists but is not executable: \(resolved)")
        case let .piqleyPlugin(version):
            state.command = val
            state.pluginProtocol = .json
            terminal.showMessage("Detected piqley plugin (schema v\(version)). Protocol set to JSON.")
            state.changed = true
        case .cliTool:
            state.command = val
            state.pluginProtocol = .pipe
            let modeItems = [
                "Once per image",
                "Once per pipeline \(ANSI.italic)(batch mode)\(ANSI.reset)",
            ]
            if let choice = terminal.selectFromList(
                title: "Run once per image or once per pipeline across all source images?",
                items: modeItems
            ) {
                state.batchProxy = choice == 0 ? BatchProxyConfig(sort: nil) : nil
            }
            state.changed = true
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
                // User pressed Esc: preserve existing args if nothing was entered yet
                return args.isEmpty ? existing : args
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
                footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  \u{23CE} edit  d delete  Esc done")
            )

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
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
                            hint: Self.envValueHint,
                            completions: templateCompletions,
                            defaultValue: match.templateValue
                        ) {
                            env[input] = value
                        }
                    } else {
                        // Custom variable name, no pre-fill
                        let templateCompletions = fieldCompletions.map(\.templateValue)
                        if let value = terminal.promptWithAutocomplete(
                            title: "Value for \(input)",
                            hint: Self.envValueHint,
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
                        hint: Self.envValueHint,
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
            try StageFileManager.saveStages(stages, to: rulesDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    private func quit() {
        StageFileManager.cleanupEmptyStageFiles(stages: stages, pluginDir: rulesDir)
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
