import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct PluginCommandEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "command",
        abstract: "Edit binary command configuration for a plugin's stages."
    )

    @Argument(help: "The plugin identifier to edit commands for.")
    var pluginID: String

    func run() throws {
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            print("Error: Plugin '\(pluginID)' not found at \(pluginDir.path)")
            throw ExitCode(1)
        }

        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
        var stages = PluginDiscovery.loadStages(
            from: pluginDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.command")
        )

        if stages.isEmpty {
            for hook in Hook.canonicalOrder {
                stages[hook.rawValue] = StageConfig(preRules: nil, binary: nil, postRules: nil)
            }
        }

        let wizard = CommandEditWizard(pluginID: pluginID, stages: stages, pluginDir: pluginDir)
        try wizard.run()
    }
}
