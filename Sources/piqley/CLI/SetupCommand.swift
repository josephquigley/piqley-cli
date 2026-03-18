import ArgumentParser
import Foundation
import Logging

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up piqley configuration and install bundled plugins"
    )

    private var logger: Logger { Logger(label: "piqley.setup") }

    func run() async throws {
        print("Welcome to piqley setup.\n")

        var config = AppConfig()

        // Auto-discover preference
        let autoDiscoverInput = prompt("Auto-discover new plugins from ~/.config/piqley/plugins/? [Y/n]: ",
                                       default: "Y")
        config.autoDiscoverPlugins = autoDiscoverInput.lowercased() != "n"

        // Seed default pipeline with bundled plugins
        config.pipeline["pre-process"] = ["piqley-metadata", "piqley-resize"]

        // Save config
        try config.save()
        print("\nConfig saved to \(AppConfig.configURL.path)")

        // Install bundled plugins
        installBundledPlugins()

        print("\nSetup complete. Run 'piqley secret set <plugin> <key>' to configure plugin credentials.")
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
