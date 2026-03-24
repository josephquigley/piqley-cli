import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct PluginRulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Interactively edit rules for a plugin within a workflow."
    )

    @Argument(help: "The plugin identifier (or workflow name if two arguments given).")
    var firstArg: String

    @Argument(help: "The plugin identifier when first argument is a workflow name.")
    var secondArg: String?

    func run() throws {
        let (workflowName, pluginID) = try resolveArguments()

        // Load workflow
        let workflow = try WorkflowStore.load(name: workflowName)

        // Verify plugin is in the workflow's pipeline
        let pipelinePlugins = Set(workflow.pipeline.values.flatMap(\.self))
        guard pipelinePlugins.contains(pluginID) else {
            throw CleanError("Plugin '\(pluginID)' is not in workflow '\(workflowName)'")
        }

        // Resolve plugin directory (for manifest/dependencies only)
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw CleanError("Plugin '\(pluginID)' not found at \(pluginDir.path)")
        }

        // Load manifest
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        // Load stages from workflow rules dir (not plugin dir)
        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginID
        )
        let stagesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.stages)
        let registry = try StageRegistry.load(from: stagesDir)
        let knownHooks = registry.allKnownNames
        var (stages, _) = PluginDiscovery.loadStages(
            from: rulesDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.rules")
        )

        // Ensure all active stages are present (in-memory only)
        for stageName in registry.executionOrder where stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Build field info from all installed plugins
        var deps: [FieldDiscovery.DependencyInfo] = []
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in pluginDirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let mURL = dir.appendingPathComponent(PluginFile.manifest)
                if let data = try? Data(contentsOf: mURL),
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

        // Build context and launch wizard
        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: pluginID,
            stages: stages
        )

        let dependencyIDs = Set(manifest.dependencyIdentifiers)
        let wizard = RulesWizard(context: context, rulesDir: rulesDir, dependencyIdentifiers: dependencyIDs)
        try wizard.run()
    }

    private func resolveArguments() throws -> (workflowName: String, pluginID: String) {
        if let pluginID = secondArg {
            // Explicit: piqley rules <workflow> <plugin>
            return (firstArg, pluginID)
        }

        // Single arg: check if it's a plugin identifier
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        let isPlugin = FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent(firstArg).path
        )

        if isPlugin {
            // Fallback to sole workflow
            let workflows = try WorkflowStore.list()
            guard workflows.count == 1, let workflowName = workflows.first else {
                throw CleanError(
                    "Multiple workflows exist. Specify the workflow: piqley rules <workflow> \(firstArg)"
                )
            }
            return (workflowName, firstArg)
        }

        throw CleanError(
            "Plugin '\(firstArg)' not found. Usage: piqley rules [workflow] <plugin>"
        )
    }
}
