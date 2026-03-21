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

        // Install bundled plugins first so we can discover them
        installBundledPlugins()

        // Seed workflows directory with default workflow
        try WorkflowStore.seedDefault()

        // Discover all plugins
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
        let plugins = try discovery.loadManifests()

        if !plugins.isEmpty {
            // Prompt for workflow name
            let workflowName = prompt("Workflow name [default]: ", default: "default")

            // Load or create the workflow
            var workflow: Workflow
            if WorkflowStore.exists(name: workflowName) {
                workflow = try WorkflowStore.load(name: workflowName)
            } else {
                workflow = .empty(name: workflowName, displayName: workflowName)
                try WorkflowStore.save(workflow)
            }

            print("\nOpening workflow editor...\n")

            // Drop into the workflow editor
            let wizard = ConfigWizard(workflow: workflow, discoveredPlugins: plugins)
            wizard.run()

            // Run plugin setup scanners
            print("\nConfiguring plugins...\n")
            let secretStore = makeDefaultSecretStore()
            var scanner = PluginSetupScanner(
                secretStore: secretStore,
                inputSource: StdinInputSource()
            )
            for plugin in plugins {
                try scanner.scan(plugin: plugin)
            }
        } else {
            print("Workflows directory created at \(WorkflowStore.workflowsDirectory.path)")
            print("Default workflow saved.")
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
