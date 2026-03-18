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
            let hook: Hook

            if nonInteractive {
                guard let pluginName else {
                    throw ValidationError("Non-interactive mode requires a plugin name argument")
                }
                name = pluginName
                hook = .preProcess
            } else {
                if let pluginName {
                    name = pluginName
                } else {
                    print("Plugin name: ", terminator: "")
                    guard let input = readLine(), !input.isEmpty else {
                        throw ValidationError("Plugin name must not be empty")
                    }
                    name = input
                }

                print("\nWhich hook should this plugin run on?")
                let hooks = Hook.canonicalOrder
                for (index, hookOption) in hooks.enumerated() {
                    print("  \(index + 1). \(hookOption.rawValue)")
                }
                print("Choose [\(Hook.preProcess.rawValue)]: ", terminator: "")
                let hookInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                if hookInput.isEmpty {
                    hook = .preProcess
                } else if let index = Int(hookInput), (1 ... hooks.count).contains(index) {
                    hook = hooks[index - 1]
                } else {
                    throw ValidationError("Invalid hook selection: \(hookInput)")
                }
            }

            try Self.validatePluginName(name)

            let pluginDir = pluginsDirectory.appendingPathComponent(name)

            if FileManager.default.fileExists(atPath: pluginDir.path) {
                throw ValidationError("Plugin '\(name)' already exists at \(pluginDir.path)")
            }

            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let manifest = try buildManifest {
                Name(name)
                ProtocolVersion("1")
                Hooks {
                    HookEntry(hook)
                }
            }
            try manifest.writeValidated(to: pluginDir)

            let config: PluginConfig = if !noExamples, !nonInteractive {
                buildConfig {
                    Rules {
                        ConfigRule(
                            match: .field(
                                .original(.model),
                                pattern: .exact("Canon EOS R5"),
                                hook: hook == .preProcess ? nil : hook
                            ),
                            emit: .values(field: "tags", ["Canon", "EOS R5"])
                        )
                    }
                }
            } else {
                buildConfig {}
            }
            try config.write(to: pluginDir)

            print("Created plugin '\(name)' at \(pluginDir.path)")
        }
    }
}
