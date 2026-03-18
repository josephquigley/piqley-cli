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

        /// Parses hook selection input supporting single numbers, ranges (e.g. "1-4"),
        /// and comma-separated values (e.g. "1,3").
        static func parseHookSelection(_ input: String, from hooks: [Hook]) throws -> [Hook] {
            let validRange = 1 ... hooks.count
            var indices: [Int] = []

            let parts = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for part in parts {
                if part.contains("-") {
                    let bounds = part.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard bounds.count == 2,
                          let start = Int(bounds[0]),
                          let end = Int(bounds[1]),
                          validRange.contains(start),
                          validRange.contains(end),
                          start <= end
                    else {
                        throw ValidationError("Invalid hook selection: \(input)")
                    }
                    indices.append(contentsOf: start ... end)
                } else if let index = Int(part), validRange.contains(index) {
                    indices.append(index)
                } else {
                    throw ValidationError("Invalid hook selection: \(input)")
                }
            }

            // Deduplicate while preserving order
            var seen = Set<Int>()
            let unique = indices.filter { seen.insert($0).inserted }

            guard !unique.isEmpty else {
                throw ValidationError("Invalid hook selection: \(input)")
            }

            return unique.map { hooks[$0 - 1] }
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
            let selectedHooks: [Hook]

            if nonInteractive {
                guard let pluginName else {
                    throw ValidationError("Non-interactive mode requires a plugin name argument")
                }
                name = pluginName
                selectedHooks = [.preProcess]
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

                let allHooks = Hook.canonicalOrder
                print("\nWhich hook(s) should this plugin run on?")
                for (index, hookOption) in allHooks.enumerated() {
                    print("  \(index + 1). \(hookOption.rawValue)")
                }
                print("Choose (e.g. 1, 1-4, 1,3) [\(Hook.preProcess.rawValue)]: ", terminator: "")
                let hookInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                if hookInput.isEmpty {
                    selectedHooks = [.preProcess]
                } else {
                    selectedHooks = try Self.parseHookSelection(hookInput, from: allHooks)
                }
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
                        for hook in selectedHooks {
                            HookEntry(hook)
                        }
                    }
                }
            } else {
                try buildManifest {
                    Name(name)
                    ProtocolVersion("1")
                    Hooks {
                        for hook in selectedHooks {
                            HookEntry(hook)
                        }
                    }
                }
            }
            try manifest.writeValidated(to: pluginDir)

            let exampleHook = selectedHooks.first!
            let hookScope: Hook? = exampleHook == .preProcess ? nil : exampleHook
            let config: PluginConfig = if includeExamples {
                buildConfig {
                    Values {
                        "outputQuality" => 85
                        "tagPrefix" => "auto"
                    }
                    Rules {
                        ConfigRule(
                            match: .field(
                                .original(.model),
                                pattern: .exact("Canon EOS R5"),
                                hook: hookScope
                            ),
                            emit: .values(field: "tags", ["Canon", "EOS R5"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.lensModel),
                                pattern: .glob("RF*"),
                                hook: hookScope
                            ),
                            emit: .values(field: "tags", ["RF Mount"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.iso),
                                pattern: .regex("^(3200|6400|12800|25600)$"),
                                hook: hookScope
                            ),
                            emit: .values(field: "tags", ["High ISO"])
                        )
                        ConfigRule(
                            match: .field(
                                .original(.focalLength),
                                pattern: .regex("^(85|105|135)$"),
                                hook: hookScope
                            ),
                            emit: .keywords(["Portrait"])
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
