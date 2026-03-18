import ArgumentParser
import Foundation
import Logging
import PiqleyCore
import PiqleyPluginSDK

struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins",
        subcommands: [SetupSubcommand.self, InitSubcommand.self]
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
                guard let plugin = plugins.first(where: { $0.name == name }) else {
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

        @Argument(help: "Plugin name")
        var pluginName: String?

        @Flag(help: "Skip example rules in generated config")
        var noExamples = false

        @Flag(help: "Non-interactive mode (requires name argument)")
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

        static func validatePluginName(_ name: String) throws {
            if name.isEmpty {
                throw ValidationError("Plugin name must not be empty")
            }
            if name == ReservedName.original {
                throw ValidationError("'original' is a reserved name")
            }
            if name.contains("/") || name.contains("\\") || name.contains("..") {
                throw ValidationError("Plugin name must not contain path separators")
            }
            if name.contains(where: \.isWhitespace) {
                throw ValidationError("Plugin name must not contain whitespace")
            }
        }

        func run() throws {
            try execute(pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory)
        }

        /// Core logic, extracted for testability (injectable plugins directory).
        func execute(pluginsDirectory: URL) throws {
            let name: String

            if nonInteractive {
                guard let pluginName else {
                    throw ValidationError("Non-interactive mode requires a plugin name argument")
                }
                name = pluginName
            } else if let pluginName {
                name = pluginName
            } else {
                print("Plugin name: ", terminator: "")
                guard let input = readLine(), !input.isEmpty else {
                    throw ValidationError("Plugin name must not be empty")
                }
                name = input
            }

            try Self.validatePluginName(name)

            let pluginDir = pluginsDirectory.appendingPathComponent(name)

            if FileManager.default.fileExists(atPath: pluginDir.path) {
                throw ValidationError("Plugin '\(name)' already exists at \(pluginDir.path)")
            }

            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let includeExamples = !noExamples && !nonInteractive

            let allHooks = Hook.canonicalOrder

            let manifest: PluginManifest = if includeExamples {
                try buildManifest {
                    Name(name)
                    ProtocolVersion("1")
                    try PluginVersion("0.1.0")
                    ConfigEntries {
                        Value("outputQuality", type: .int, default: 85)
                        Value("tagPrefix", type: .string, default: "auto")
                        Secret("API_KEY", type: .string)
                    }
                    Dependencies {
                        "example-dependency"
                    }
                    Hooks {
                        for hook in allHooks {
                            HookEntry(
                                hook,
                                command: "echo",
                                args: ["[\(hook.rawValue)]", "tags: Canon, EOS R5, RF Mount, High ISO, Portrait, Piqley Emulsions LLC"],
                                timeout: 30
                            )
                        }
                    }
                }
            } else {
                try buildManifest {
                    Name(name)
                    ProtocolVersion("1")
                    Hooks {
                        for hook in allHooks {
                            HookEntry(hook)
                        }
                    }
                }
            }
            let manifestInstructions = """
            This is your plugin's manifest. It declares the plugin's identity, \
            configuration schema, dependencies, and hook entries. Each hook can \
            optionally specify a command to run; hooks without a command are \
            declarative-only and rely on the rules in config.json. Remove any hooks \
            or config entries you don't need.
            """
            try Self.writeJSON(manifest.encode(), instructions: manifestInstructions, to: pluginDir, fileName: PluginFile.manifest)

            let config: PluginConfig = if includeExamples {
                buildConfig {
                    Values {
                        "outputQuality" => 85
                        "tagPrefix" => "auto"
                    }
                    Rules {
                        // pre-process: tag from original image metadata
                        ConfigRule(
                            match: .field(
                                .original(.model),
                                pattern: .exact("Canon EOS R5"),
                                hook: .preProcess
                            ),
                            emit: .values(field: "tags", ["Canon", "EOS R5"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.lensModel),
                                pattern: .glob("RF*"),
                                hook: .preProcess
                            ),
                            emit: .values(field: "tags", ["RF Mount"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.iso),
                                pattern: .regex("^(3200|6400|12800|25600)$"),
                                hook: .preProcess
                            ),
                            emit: .values(field: "tags", ["High ISO"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.focalLength),
                                pattern: .regex("^(85|105|135)$"),
                                hook: .preProcess
                            ),
                            emit: .keywords(["Portrait"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.make),
                                pattern: .glob("*Kodak*"),
                                hook: .preProcess
                            ),
                            emit: .values(field: "tags", ["Kodak"])
                        )

                        // post-process: remap a pre-process tag to a new value
                        ConfigRule(
                            match: .field(
                                .dependency(name, key: "tags"),
                                pattern: .exact("Kodak"),
                                hook: .postProcess
                            ),
                            emit: .values(field: "tags", ["Piqley Emulsions, LLC"])
                        )
                    }
                }
            } else {
                buildConfig {}
            }
            let configInstructions = """
            This is your plugin's runtime configuration. The 'values' section holds \
            key-value settings that your plugin reads at runtime. The 'rules' section \
            contains declarative metadata-matching rules: each rule matches a field \
            (from original image metadata or a dependency's output) using exact, glob, \
            or regex patterns, and emits tags or keywords. Rules scoped to a hook run \
            only during that stage. A rule in post-process can match tags emitted by \
            pre-process using '<plugin-name>:<field>' syntax.
            """
            try Self.writeJSON(config, instructions: configInstructions, to: pluginDir, fileName: PluginFile.config)

            print("Created plugin '\(name)' at \(pluginDir.path)")
        }
    }
}
