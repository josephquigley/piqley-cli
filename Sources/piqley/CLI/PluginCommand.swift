import ArgumentParser
import Foundation
import Logging
import PiqleyCore
import PiqleyPluginSDK

struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins",
        subcommands: [
            ListSubcommand.self, SetupSubcommand.self, InitSubcommand.self,
            CreateSubcommand.self, InstallSubcommand.self, UpdateSubcommand.self,
            UninstallSubcommand.self, EditSubcommand.self,
        ]
    )

    struct ListSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all installed plugins"
        )

        func run() throws {
            let workflows: [Workflow]
            do {
                workflows = try WorkflowStore.loadAll()
            } catch {
                throw CleanError("Failed to load workflows: \(formatError(error))\nRun 'piqley setup' first.")
            }

            let (_, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()

            if allPlugins.isEmpty {
                print("No plugins installed.")
                return
            }

            for plugin in allPlugins {
                let version = plugin.manifest.pluginVersion.map { "\($0)" } ?? "-"
                // Show which workflows contain this plugin
                let workflowNames = workflows.filter { workflow in
                    workflow.pipeline.values.flatMap(\.self).contains(plugin.identifier)
                }.map(\.name)
                let workflowInfo = workflowNames.isEmpty ? "not in any workflow" : workflowNames.joined(separator: ", ")

                print("\(plugin.identifier)")
                print("  Name:      \(plugin.name)")
                print("  Version:   \(version)")
                if let desc = plugin.manifest.description, !desc.isEmpty {
                    print("  About:     \(desc)")
                }
                print("  Workflows: \(workflowInfo)")
                print()
            }

            print("\(allPlugins.count) plugin(s) installed")
        }
    }

    struct SetupSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Run interactive setup for plugins"
        )

        @Argument(help: "Plugin name (runs all plugins if omitted)")
        var pluginName: String?

        @Flag(help: "Force re-setup (clears existing config values and isSetUp)")
        var force = false

        func run() throws {
            let workflows = try WorkflowStore.list()
            if workflows.isEmpty {
                throw CleanError("No workflows found. Run 'piqley setup' first.")
            }

            let (_, plugins) = try WorkflowCommand.loadRegistryAndPlugins()

            let secretStore = makeDefaultSecretStore()
            var scanner = PluginSetupScanner(
                secretStore: secretStore,
                configStore: .default,
                inputSource: StdinInputSource()
            )

            let targetPlugins: [LoadedPlugin]
            if let name = pluginName {
                guard let plugin = plugins.first(where: { $0.identifier == name || $0.name == name }) else {
                    throw CleanError("Plugin '\(name)' not found")
                }
                targetPlugins = [plugin]
            } else {
                targetPlugins = plugins
            }

            for plugin in targetPlugins {
                try scanner.scan(plugin: plugin, force: force)
            }

            print("\nPlugin setup complete.")
        }
    }

    struct InitSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Create a new declarative-only plugin"
        )

        @Argument(help: "Plugin identifier (reverse-TLD, e.g. com.example.myplugin)")
        var pluginIdentifier: String?

        @Argument(help: "Plugin display name (optional; derived from identifier if omitted)")
        var displayName: String?

        @Option(help: "Plugin description (non-interactive; interactive mode opens $EDITOR)")
        var description: String?

        @Flag(help: "Skip example rules in generated config")
        var noExamples = false

        @Flag(help: "Non-interactive mode (requires identifier argument)")
        var nonInteractive = false

        /// Writes JSON data to a file, injecting a `_comment` key at the top level.
        static func writeJSON(_ encodable: any Encodable, comment: String, to directory: URL, fileName: String) throws {
            let data = try JSONEncoder.piqleyPrettyPrint.encode(encodable)

            var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            dict["_comment"] = comment
            let output = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])

            try output.write(to: directory.appendingPathComponent(fileName))
        }

        /// Writes pre-encoded JSON data to a file, injecting a `_comment` key at the top level.
        static func writeJSON(_ data: Data, comment: String, to directory: URL, fileName: String) throws {
            var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            dict["_comment"] = comment
            let output = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])

            try output.write(to: directory.appendingPathComponent(fileName))
        }

        /// Backward-compatible alias used by CreateCommand.
        static func validatePluginName(_ name: String) throws {
            try validatePluginIdentifier(name)
        }

        /// Sanitizes and validates a plugin identifier.
        /// Lowercases the input and strips characters that aren't alphanumeric, `.`, `-`, or `_`.
        static func sanitizePluginIdentifier(_ raw: String) throws -> String {
            let sanitized = String(
                raw.lowercased().unicodeScalars.filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "."
                        || scalar == "-"
                        || scalar == "_"
                }
            )
            if sanitized.isEmpty {
                throw ValidationError("Plugin identifier must not be empty")
            }
            let reservedNames = [ReservedName.original, ReservedName.skip]
            if reservedNames.contains(sanitized) {
                throw ValidationError("'\(sanitized)' is a reserved identifier")
            }
            return sanitized
        }

        static func validatePluginIdentifier(_ identifier: String) throws {
            _ = try sanitizePluginIdentifier(identifier)
        }

        func run() throws {
            try execute(pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory)
        }

        /// Core logic, extracted for testability (injectable plugins directory and description prompt).
        func execute(
            pluginsDirectory: URL,
            descriptionPrompt: (String) -> String? = Self.promptForDescription
        ) throws {
            let identifier: String
            let resolvedDisplayName: String
            let resolvedDescription: String?

            if nonInteractive {
                guard let pluginIdentifier else {
                    throw ValidationError("Non-interactive mode requires a plugin identifier argument")
                }
                identifier = try Self.sanitizePluginIdentifier(pluginIdentifier)
                resolvedDisplayName = displayName ?? identifier
                resolvedDescription = description
            } else if let pluginIdentifier {
                identifier = try Self.sanitizePluginIdentifier(pluginIdentifier)
                resolvedDisplayName = displayName ?? identifier
                resolvedDescription = description ?? descriptionPrompt(resolvedDisplayName)
            } else {
                print("Plugin identifier (e.g. com.example.myplugin): ", terminator: "")
                guard let identifierInput = readLine(), !identifierInput.isEmpty else {
                    throw ValidationError("Plugin identifier must not be empty")
                }
                identifier = try Self.sanitizePluginIdentifier(identifierInput)
                if identifier != identifierInput {
                    print("Sanitized to: \(identifier)")
                }

                print("Display name (press Enter to use '\(identifier)'): ", terminator: "")
                let nameInput = readLine() ?? ""
                resolvedDisplayName = nameInput.isEmpty ? identifier : nameInput
                resolvedDescription = description ?? descriptionPrompt(resolvedDisplayName)
            }

            let pluginDir = pluginsDirectory.appendingPathComponent(identifier)

            if FileManager.default.fileExists(atPath: pluginDir.path) {
                throw CleanError("Plugin '\(identifier)' already exists at \(pluginDir.path)")
            }

            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let includeExamples = !noExamples && !nonInteractive

            let manifest = if includeExamples {
                PluginManifest(
                    identifier: identifier,
                    name: resolvedDisplayName,
                    type: .mutable,
                    description: resolvedDescription,
                    pluginSchemaVersion: "1",
                    pluginVersion: SemanticVersion(major: 0, minor: 0, patch: 1),
                    config: [
                        .value(key: "outputQuality", type: .int, value: .number(85), metadata: ConfigMetadata(label: "Output Quality")),
                        .value(key: "tagPrefix", type: .string, value: .string("auto"), metadata: ConfigMetadata(label: "Tag Prefix")),
                        .secret(secretKey: "API_KEY", type: .string, metadata: ConfigMetadata(label: "API Key")),
                    ]
                )
            } else {
                PluginManifest(
                    identifier: identifier,
                    name: resolvedDisplayName,
                    type: .mutable,
                    description: resolvedDescription,
                    pluginSchemaVersion: "1"
                )
            }
            let manifestComment = """
            This is your plugin's manifest. It declares the plugin's identity and \
            configuration schema. The identifier (reverse-TLD) is the plugin's unique key. \
            Stage files (stage-pre-process.json, stage-post-process.json) define \
            declarative rules for each processing stage. Remove any config entries you don't need.
            """
            try Self.writeJSON(manifest.encode(), comment: manifestComment, to: pluginDir, fileName: PluginFile.manifest)

            let config: PluginConfig = if includeExamples {
                buildConfig {
                    Values {
                        "outputQuality" => 85
                        "tagPrefix" => "auto"
                    }
                }
            } else {
                buildConfig {}
            }
            let configComment = """
            This is your plugin's runtime configuration. The 'values' section currently holds \
            example key-value settings that your plugin could read at runtime.
            """
            try Self.writeJSON(config, comment: configComment, to: pluginDir, fileName: PluginFile.config)

            if includeExamples {
                try Self.writeExampleStageFiles(to: pluginDir, identifier: identifier)
            }

            print("Created plugin '\(identifier)' at \(pluginDir.path)")
        }

        // MARK: - Description prompt

        /// Opens $EDITOR on a temp file so the user can write a multi-line description.
        /// Returns nil if the user leaves the file empty, the editor exits with an error,
        /// or stdin is not a terminal.
        static func promptForDescription(pluginName: String) -> String? {
            guard isatty(STDIN_FILENO) != 0 else { return nil }

            print("Add a description? (opens \(editorName()); press Enter to skip) [y/N]: ", terminator: "")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !answer.isEmpty, answer != "n", answer != "no" else { return nil }

            let editor = ProcessInfo.processInfo.environment["EDITOR"]
                ?? ProcessInfo.processInfo.environment["VISUAL"]
                ?? "vi"

            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("piqley-description-\(UUID().uuidString).txt")

            let placeholder = "# Write a description for '\(pluginName)'.\n# Lines starting with # are ignored. Save and quit to continue.\n"
            do {
                try placeholder.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
            defer { try? FileManager.default.removeItem(at: tempFile) }

            print("Opening \(editor)...")

            // Use fork/exec directly so the editor inherits a real controlling
            // terminal. Swift's Process API interferes with TTY attachment even
            // when /dev/tty is used — the child gets HUP because Process sets up
            // file descriptors via posix_spawn before the shell can redirect them.
            let exitStatus = Self.runEditor(editor, file: tempFile.path)

            guard exitStatus == 0 else { return nil }

            guard let contents = try? String(contentsOf: tempFile, encoding: .utf8) else { return nil }

            let description = contents
                .components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return description.isEmpty ? nil : description
        }

        /// Launches an editor using posix_spawn with /dev/tty for stdin/stdout/stderr.
        /// Returns the editor's exit status, or -1 on failure.
        private static func runEditor(_ editor: String, file: String) -> Int32 {
            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            // Redirect stdin/stdout/stderr to /dev/tty
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/tty", O_RDWR, 0)
            posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDERR_FILENO)

            let args = [editor, file]
            let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
            defer { cArgs.forEach { $0.flatMap { free($0) } } }

            var pid: pid_t = 0
            let result = posix_spawnp(&pid, editor, &fileActions, nil, cArgs, environ)
            guard result == 0 else { return -1 }

            var status: Int32 = 0
            waitpid(pid, &status, 0)
            if (status & 0x7F) == 0 {
                return (status >> 8) & 0xFF // WEXITSTATUS
            }
            return -1 // signaled
        }

        private static func editorName() -> String {
            ProcessInfo.processInfo.environment["EDITOR"]
                ?? ProcessInfo.processInfo.environment["VISUAL"]
                ?? "vi"
        }

        // MARK: - Example stage files

        private static func writeExampleStageFiles(to pluginDir: URL, identifier: String) throws {
            let binaryConfig: [String: Any] = [
                "command": "",
                "args": [String](),
            ]

            // Pre-process stage
            let preProcessStage: [String: Any] = [
                "_comment": """
                Pre-process rules run before any binary. Match against original image \
                metadata and emit tags/keywords to your plugin's namespace.
                """,
                "binary": binaryConfig,
                "preRules": [
                    [
                        "_comment": "Tag images shot on a Canon EOS R5",
                        "match": ["field": "original:TIFF:Model", "pattern": "Canon EOS R5"],
                        "emit": [["field": "tags", "values": ["Canon", "EOS R5"]]],
                    ],
                    [
                        "_comment": "Tag images shot with an RF-mount lens (glob pattern)",
                        "match": ["field": "original:TIFF:LensModel", "pattern": "glob:RF*"],
                        "emit": [["field": "tags", "values": ["RF Mount"]]],
                    ],
                    [
                        "_comment": "Flag high-ISO shots (regex pattern matching specific values)",
                        "match": ["field": "original:EXIF:ISOSpeedRatings", "pattern": "regex:^(3200|6400|12800|25600)$"],
                        "emit": [["field": "tags", "values": ["High ISO"]]],
                    ],
                    [
                        "_comment": "Add 'Portrait' keyword for classic portrait focal lengths",
                        "match": ["field": "original:EXIF:FocalLength", "pattern": "regex:^(85|105|135)$"],
                        "emit": [["field": "keywords", "values": ["Portrait"]]],
                    ],
                ],
            ]
            try Self.writeStageJSON(preProcessStage, to: pluginDir, fileName: "stage-pre-process.json")

            // Post-process stage
            let postProcessStage: [String: Any] = [
                "_comment": """
                Post-process rules run after any binary. You can match against your own \
                plugin's output from pre-process using '<plugin-identifier>:<field>' syntax. \
                Write actions modify the image file's metadata directly.
                """,
                "binary": binaryConfig,
                "postRules": [
                    [
                        "_comment": "Replace 'Kodak' tag with fake Piqley brand name (demonstrates remove + add)",
                        "match": ["field": "\(identifier):tags", "pattern": "Kodak"],
                        "emit": [
                            ["action": "remove", "field": "tags", "values": ["Kodak"]],
                            ["field": "tags", "values": ["Piqley Emulsions, LLC"]],
                        ],
                    ],
                    [
                        "_comment": "Write IPTC keywords to the file for any Canon camera (demonstrates write actions)",
                        "match": ["field": "original:TIFF:Make", "pattern": "glob:*Canon*"],
                        "emit": [["field": "keywords", "values": ["Canon"]]],
                        "write": [["field": "IPTC:Keywords", "values": ["Canon", "piqley-processed"]]],
                    ],
                ],
            ]
            try Self.writeStageJSON(postProcessStage, to: pluginDir, fileName: "stage-post-process.json")

            // Publish stage
            let publishStage: [String: Any] = [
                "_comment": """
                Publish stage. Runs after post-process. Typically used for uploading or \
                exporting processed images.
                """,
                "binary": binaryConfig,
            ]
            try Self.writeStageJSON(publishStage, to: pluginDir, fileName: "stage-publish.json")

            // Post-publish stage
            let postPublishStage: [String: Any] = [
                "_comment": """
                Post-publish stage. Runs after publish. Typically used for cleanup, \
                notifications, or logging after images have been exported.
                """,
                "binary": binaryConfig,
            ]
            try Self.writeStageJSON(postPublishStage, to: pluginDir, fileName: "stage-post-publish.json")
        }

        private static func writeStageJSON(_ dict: [String: Any], to directory: URL, fileName: String) throws {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(fileName))
        }
    }
}
