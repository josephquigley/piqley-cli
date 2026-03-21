import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct PluginRulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Manage rules for a plugin.",
        subcommands: [PluginRulesEditCommand.self],
        defaultSubcommand: PluginRulesEditCommand.self
    )
}

struct PluginRulesEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Interactively edit rules for a plugin."
    )

    @Argument(help: "The plugin identifier to edit rules for.")
    var pluginID: String

    func run() throws {
        // 1. Resolve plugin directory
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            print("Error: Plugin '\(pluginID)' not found at \(pluginDir.path)")
            throw ExitCode(1)
        }

        // 2. Load manifest
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        // 3. Load stages (create empty ones if none exist)
        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
        var stages = PluginDiscovery.loadStages(
            from: pluginDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.rules")
        )

        // Ensure all canonical stages are present (in-memory only, not written to disk)
        for hook in Hook.canonicalOrder where stages[hook.rawValue] == nil {
            stages[hook.rawValue] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // 4. Build dependency info
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

        // 5. Build context
        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: pluginID,
            stages: stages
        )

        // 6. Launch wizard
        let wizard = RulesWizard(context: context, pluginDir: pluginDir)
        try wizard.run()
    }
}
