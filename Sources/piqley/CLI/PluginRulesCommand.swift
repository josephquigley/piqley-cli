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

struct PluginRulesEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Interactively edit rules for a plugin."
    )

    @Argument(help: "The plugin identifier to edit rules for.")
    var pluginID: String

    func run() async throws {
        // 1. Resolve plugin directory
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw ValidationError("Plugin '\(pluginID)' not found at \(pluginDir.path)")
        }

        // 2. Load manifest
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        // 3. Load stages
        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
        let stages = PluginDiscovery.loadStages(
            from: pluginDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.rules")
        )

        guard !stages.isEmpty else {
            throw ValidationError(
                "Plugin '\(pluginID)' has no stage files. Create stage files first."
            )
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

        // 6. Launch wizard (does not return — calls exit() via TermKit)
        let writeBack = RulesWizardApp.WriteBackConfig(
            pluginDir: pluginDir,
            originalStages: stages
        )

        await RulesWizardApp.run(context: context, writeBack: writeBack)
    }
}
