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
        let stagesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.stages)
        let registry = try StageRegistry.load(from: stagesDir)
        let knownHooks = registry.allKnownNames
        var (stages, _) = PluginDiscovery.loadStages(
            from: pluginDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.rules")
        )

        // Ensure all active stages are present (in-memory only, not written to disk)
        for stageName in registry.executionOrder where stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // 4. Build field info from all installed plugins
        // This includes the plugin being edited (it may reference its own fields from earlier stages).
        // Directories with missing/malformed manifests are silently skipped via try?.
        var deps: [FieldDiscovery.DependencyInfo] = []
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in pluginDirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let manifestURL = dir.appendingPathComponent(PluginFile.manifest)
                if let data = try? Data(contentsOf: manifestURL),
                   let pluginManifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
                {
                    let fields = pluginManifest.valueEntries.map(\.key)
                    if !fields.isEmpty {
                        deps.append(FieldDiscovery.DependencyInfo(
                            identifier: pluginManifest.identifier,
                            fields: fields
                        ))
                    }
                }
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
        let dependencyIDs = Set(manifest.dependencyIdentifiers)
        let wizard = RulesWizard(context: context, pluginDir: pluginDir, dependencyIdentifiers: dependencyIDs)
        try wizard.run()
    }
}
