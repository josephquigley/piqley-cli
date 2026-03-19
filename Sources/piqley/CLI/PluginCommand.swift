import ArgumentParser
import Foundation
import Logging
import PiqleyCore
import PiqleyPluginSDK

struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins",
        subcommands: [SetupSubcommand.self, InitSubcommand.self, CreateSubcommand.self, InstallSubcommand.self, ConfigSubcommand.self]
    )

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
            let config: AppConfig
            do {
                config = try AppConfig.load()
            } catch {
                throw ValidationError("Failed to load config: \(formatError(error))\nRun 'piqley setup' first.")
            }

            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests(disabled: config.disabledPlugins)

            let secretStore = makeDefaultSecretStore()
            var scanner = PluginSetupScanner(
                secretStore: secretStore,
                inputSource: StdinInputSource()
            )

            let targetPlugins: [LoadedPlugin]
            if let name = pluginName {
                guard let plugin = plugins.first(where: { $0.identifier == name || $0.name == name }) else {
                    throw ValidationError("Plugin '\(name)' not found")
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

        /// Writes JSON data to a file, injecting an `instructionsForUse` key at the top level.
        static func writeJSON(_ encodable: any Encodable, instructions: String, to directory: URL, fileName: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(encodable)

            var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            dict["_instructions"] = instructions
            let output = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])

            try output.write(to: directory.appendingPathComponent(fileName))
        }

        /// Writes pre-encoded JSON data to a file, injecting an `_instructions` key at the top level.
        static func writeJSON(_ data: Data, instructions: String, to directory: URL, fileName: String) throws {
            var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            dict["_instructions"] = instructions
            let output = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])

            try output.write(to: directory.appendingPathComponent(fileName))
        }

        /// Backward-compatible alias used by CreateCommand.
        static func validatePluginName(_ name: String) throws {
            try validatePluginIdentifier(name)
        }

        static func validatePluginIdentifier(_ identifier: String) throws {
            if identifier.isEmpty {
                throw ValidationError("Plugin identifier must not be empty")
            }
            if identifier == ReservedName.original {
                throw ValidationError("'original' is a reserved identifier")
            }
            if identifier.contains("/") || identifier.contains("\\") || identifier.contains("..") {
                throw ValidationError("Plugin identifier must not contain path separators")
            }
            if identifier.contains(where: \.isWhitespace) {
                throw ValidationError("Plugin identifier must not contain whitespace")
            }
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
                identifier = pluginIdentifier
                resolvedDisplayName = displayName ?? identifier
                resolvedDescription = description
            } else if let pluginIdentifier {
                identifier = pluginIdentifier
                resolvedDisplayName = displayName ?? identifier
                resolvedDescription = description ?? descriptionPrompt(resolvedDisplayName)
            } else {
                print("Plugin identifier (e.g. com.example.myplugin): ", terminator: "")
                guard let identifierInput = readLine(), !identifierInput.isEmpty else {
                    throw ValidationError("Plugin identifier must not be empty")
                }
                identifier = identifierInput

                print("Display name (press Enter to use '\(identifier)'): ", terminator: "")
                let nameInput = readLine() ?? ""
                resolvedDisplayName = nameInput.isEmpty ? identifier : nameInput
                resolvedDescription = description ?? descriptionPrompt(resolvedDisplayName)
            }

            try Self.validatePluginIdentifier(identifier)

            let pluginDir = pluginsDirectory.appendingPathComponent(identifier)

            if FileManager.default.fileExists(atPath: pluginDir.path) {
                throw ValidationError("Plugin '\(identifier)' already exists at \(pluginDir.path)")
            }

            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let includeExamples = !noExamples && !nonInteractive

            let manifest = if includeExamples {
                PluginManifest(
                    identifier: identifier,
                    name: resolvedDisplayName,
                    description: resolvedDescription,
                    pluginProtocolVersion: "1",
                    pluginVersion: SemanticVersion(major: 0, minor: 0, patch: 1),
                    config: [
                        .value(key: "outputQuality", type: .int, value: .number(85)),
                        .value(key: "tagPrefix", type: .string, value: .string("auto")),
                        .secret(secretKey: "API_KEY", type: .string),
                    ]
                )
            } else {
                PluginManifest(
                    identifier: identifier,
                    name: resolvedDisplayName,
                    description: resolvedDescription,
                    pluginProtocolVersion: "1"
                )
            }
            let manifestInstructions = """
            This is your plugin's manifest. It declares the plugin's identity and \
            configuration schema. The identifier (reverse-TLD) is the plugin's unique key. \
            Stage files (stage-pre-process.json, stage-post-process.json) define \
            declarative rules for each processing stage. Remove any config entries you don't need.
            """
            try Self.writeJSON(manifest.encode(), instructions: manifestInstructions, to: pluginDir, fileName: PluginFile.manifest)

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
            let configInstructions = """
            This is your plugin's runtime configuration. The 'values' section holds \
            key-value settings that your plugin reads at runtime. Declarative rules \
            are defined in stage files (stage-pre-process.json, stage-post-process.json).
            """
            try Self.writeJSON(config, instructions: configInstructions, to: pluginDir, fileName: PluginFile.config)

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

            // Launch the editor via /bin/sh with explicit /dev/tty redirection.
            // This ensures the editor gets a real terminal even under `swift run`.
            let shellSafeEditor = editor.replacingOccurrences(of: "'", with: "'\\''")
            let shellSafePath = tempFile.path.replacingOccurrences(of: "'", with: "'\\''")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "'\(shellSafeEditor)' '\(shellSafePath)' </dev/tty >/dev/tty 2>/dev/tty"]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }

            guard process.terminationStatus == 0 else { return nil }

            guard let contents = try? String(contentsOf: tempFile, encoding: .utf8) else { return nil }

            let description = contents
                .components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return description.isEmpty ? nil : description
        }

        private static func editorName() -> String {
            ProcessInfo.processInfo.environment["EDITOR"]
                ?? ProcessInfo.processInfo.environment["VISUAL"]
                ?? "vi"
        }

        // MARK: - Example stage files

        private static func writeExampleStageFiles(to pluginDir: URL, identifier: String) throws {
            // Pre-process stage
            let preProcessStage: [String: Any] = [
                "_instructions": """
                Pre-process rules run before any binary. Match against original image \
                metadata and emit tags/keywords to your plugin's namespace.
                """,
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
                "_instructions": """
                Post-process rules run after any binary. You can match against your own \
                plugin's output from pre-process using '<plugin-identifier>:<field>' syntax. \
                Write actions modify the image file's metadata directly.
                """,
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

            // Empty stage files for remaining stages
            let publishStage: [String: Any] = [
                "_instructions": """
                Publish stage. Runs after post-process. Typically used for uploading or \
                exporting processed images. Add preRules, a binary, or postRules as needed.
                """,
            ]
            try Self.writeStageJSON(publishStage, to: pluginDir, fileName: "stage-publish.json")

            let postPublishStage: [String: Any] = [
                "_instructions": """
                Post-publish stage. Runs after publish. Typically used for cleanup, \
                notifications, or logging after images have been exported. Add preRules, \
                a binary, or postRules as needed.
                """,
            ]
            try Self.writeStageJSON(postPublishStage, to: pluginDir, fileName: "stage-post-publish.json")
        }

        private static func writeStageJSON(_ dict: [String: Any], to directory: URL, fileName: String) throws {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(fileName))
        }
    }

    struct ConfigSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Open a plugin's config file in your editor"
        )

        @Argument(help: "Plugin name")
        var pluginName: String

        func run() throws {
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let configPath = pluginsDir
                .appendingPathComponent(pluginName)
                .appendingPathComponent(PluginFile.config)
                .path

            guard FileManager.default.fileExists(atPath: configPath) else {
                throw ValidationError("Config file not found for plugin '\(pluginName)' at \(configPath)")
            }

            try openInEditor(configPath)
        }
    }
}
