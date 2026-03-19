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

            let manifest: PluginManifest = if includeExamples {
                try buildManifest {
                    Identifier(name)
                    Name(name)
                    ProtocolVersion("1")
                    try PluginVersion("0.1.0")
                    ConfigEntries {
                        Value("outputQuality", type: .int, default: 85)
                        Value("tagPrefix", type: .string, default: "auto")
                        Secret("API_KEY", type: .string)
                    }
                }
            } else {
                try buildManifest {
                    Identifier(name)
                    Name(name)
                    ProtocolVersion("1")
                }
            }
            let manifestInstructions = """
            This is your plugin's manifest. It declares the plugin's identity, \
            configuration schema, and dependencies. Stage files (stage-<hook>.json) \
            define pre-rules, binary execution, and post-rules for each hook. \
            Remove any config entries you don't need.
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
            are now defined in stage files (stage-<hook>.json) as preRules and \
            postRules sections.
            """
            try Self.writeJSON(config, instructions: configInstructions, to: pluginDir, fileName: PluginFile.config)

            print("Created plugin '\(name)' at \(pluginDir.path)")
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
