import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up piqley configuration and install bundled plugins"
    )

    private var logger: Logger { Logger(label: "piqley.setup") }

    private static let logo = """
        (\\____/)
        / @__@ \\
       (  (oo)  )
        `-.~~.-'
         /    \\
       @/      \\_
      (/ /    \\ \\)
       WW`----'WW
                        _
       _ __ (_)  __ _  | |  ___  _   _
      | '_ \\| | / _` | | | / _ \\| | | |
      | |_) | || (_| | | ||  __/| |_| |
      | .__/|_| \\__, | |_| \\___| \\__, |
      |_|          |_|            |___/
    """

    func run() async throws {
        print(Self.logo)
        print()

        var config = AppConfig()

        // Auto-discover preference
        let autoDiscoverInput = prompt("Auto-discover new plugins from ~/.config/piqley/plugins/? [Y/n]: ",
                                       default: "Y")
        config.autoDiscoverPlugins = autoDiscoverInput.lowercased() != "n"

        // Seed default pipeline with bundled plugins
        config.pipeline[Hook.preProcess.rawValue] = ["piqley-metadata", "piqley-resize"]

        // Save config
        try config.save()
        print("\nConfig saved to \(AppConfig.configURL.path)")

        // Install bundled plugins
        installBundledPlugins()

        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
        let plugins = try discovery.loadManifests(disabled: config.disabledPlugins)

        if !plugins.isEmpty {
            print("\nConfiguring plugins...\n")
            let secretStore = makeDefaultSecretStore()
            var scanner = PluginSetupScanner(
                secretStore: secretStore,
                inputSource: StdinInputSource()
            )
            for plugin in plugins {
                try scanner.scan(plugin: plugin)
            }
        }

        print("\nSetup complete.")
    }

    // MARK: - Bundled Plugin Install

    private func installBundledPlugins() {
        // Bundled plugins live alongside the piqley binary at ../lib/piqley/plugins/
        guard let executablePath = ProcessInfo.processInfo.arguments.first else { return }
        let execURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let bundledPluginsDir = execURL
            .deletingLastPathComponent() // bin/
            .deletingLastPathComponent() // prefix/
            .appendingPathComponent("lib/piqley/plugins")

        guard FileManager.default.fileExists(atPath: bundledPluginsDir.path) else {
            logger.debug("No bundled plugins directory at \(bundledPluginsDir.path) — skipping")
            return
        }

        let targetDir = PipelineOrchestrator.defaultPluginsDirectory
        do {
            let bundled = try FileManager.default.contentsOfDirectory(
                at: bundledPluginsDir, includingPropertiesForKeys: [.isDirectoryKey]
            )
            for src in bundled where (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let dest = targetDir.appendingPathComponent(src.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    logger.debug("Plugin '\(src.lastPathComponent)' already installed — skipping")
                    continue
                }
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: src, to: dest)
                print("Installed bundled plugin: \(src.lastPathComponent)")
            }
        } catch {
            logger.warning("Failed to install bundled plugins: \(error)")
        }
    }

    // MARK: - Input Helpers

    private func prompt(_ message: String, default defaultValue: String) -> String {
        print(message, terminator: "")
        let input = readLine(strippingNewline: true) ?? ""
        return input.isEmpty ? defaultValue : input
    }

    private func promptRequired(_ message: String) -> String {
        while true {
            print(message, terminator: "")
            let input = readLine(strippingNewline: true) ?? ""
            if !input.isEmpty { return input }
            print("Value is required.")
        }
    }
}
