import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View or edit the piqley config",
        subcommands: [EditSubcommand.self, OpenSubcommand.self, AddPluginSubcommand.self, RemovePluginSubcommand.self]
    )

    struct OpenSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open the config file in your editor"
        )

        func run() throws {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let configPath = home.appendingPathComponent(PiqleyPath.config).path

            guard FileManager.default.fileExists(atPath: configPath) else {
                throw ValidationError("Config file not found at \(configPath)\nRun 'piqley setup' first.")
            }

            try openInEditor(configPath)
        }
    }

    struct EditSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit pipeline configuration with an interactive wizard"
        )

        func run() throws {
            let config: AppConfig
            do {
                config = try AppConfig.load()
            } catch {
                throw ValidationError("Failed to load config: \(formatError(error))\nRun 'piqley setup' first.")
            }

            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            let wizard = ConfigWizard(config: config, discoveredPlugins: plugins)
            wizard.run()
        }
    }
}

func openInEditor(_ path: String) throws {
    let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [editor, path]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw ValidationError("Editor exited with status \(process.terminationStatus)")
    }
}
