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

        // Ensure all canonical stages are present (in-memory only, not written to disk)
        for hook in Hook.canonicalOrder where stages[hook.rawValue] == nil {
            stages[hook.rawValue] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Load manifest and build available fields for env var autocompletion
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        var deps: [FieldDiscovery.DependencyInfo] = []
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        for depID in manifest.dependencyIdentifiers {
            let depDir = pluginsDir.appendingPathComponent(depID)
            let depManifestURL = depDir.appendingPathComponent(PluginFile.manifest)
            if let depData = try? Data(contentsOf: depManifestURL),
               let depManifest = try? JSONDecoder().decode(PluginManifest.self, from: depData)
            {
                let fields = depManifest.valueEntries.map(\.key)
                deps.append(FieldDiscovery.DependencyInfo(identifier: depID, fields: fields))
            }
        }

        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)

        let wizard = CommandEditWizard(
            pluginID: pluginID, stages: stages, pluginDir: pluginDir,
            availableFields: availableFields
        )
        try wizard.run()
    }
}
