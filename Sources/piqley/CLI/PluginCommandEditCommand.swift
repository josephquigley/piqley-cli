import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct PluginCommandEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "command",
        abstract: "Edit binary command configuration for a plugin's stages within a workflow."
    )

    @Argument(help: "The plugin identifier (or workflow name if two arguments given).")
    var firstArg: String?

    @Argument(help: "The plugin identifier when first argument is a workflow name.")
    var secondArg: String?

    func run() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: firstArg, secondArg: secondArg,
            usageHint: "piqley plugin command"
        )
        let (workflowName, pluginID) = try resolver.resolve()

        // Verify plugin is in the workflow's pipeline
        let workflow = try WorkflowStore.load(name: workflowName)
        let plugins = Set(workflow.pipeline.values.flatMap(\.self))
        guard plugins.contains(pluginID) else {
            throw CleanError("Plugin '\(pluginID)' is not in workflow '\(workflowName)'")
        }

        // Plugin directory for manifest loading and binary probing
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw CleanError("Plugin '\(pluginID)' not found at \(pluginDir.path)")
        }

        // Workflow rules directory for stage file I/O
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
            logger: Logger(label: "piqley.command")
        )

        // Ensure all active stages are present (in-memory only, not written to disk)
        for stageName in registry.executionOrder where stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Load manifest and build available fields for env var autocompletion
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)

        guard manifest.type == .mutable else {
            throw CleanError(
                "'\(manifest.name)' is a static plugin and cannot be modified. "
                    + "Config values can be changed with 'piqley plugin config'."
            )
        }

        // Discover fields from upstream plugins' rules files
        let rulesBaseDir = WorkflowStore.rulesDirectory(name: workflowName)
        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: workflow.pipeline,
            targetPlugin: pluginID,
            stageOrder: registry.executionOrder,
            rulesBaseDir: rulesBaseDir
        )

        // Add the target plugin's own consumed fields
        var allDeps = deps
        if !manifest.consumedFields.isEmpty {
            let ownFields = manifest.consumedFields.map(\.name)
            allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: ownFields))
        }

        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: allDeps)

        let wizard = CommandEditWizard(
            pluginID: pluginID, stages: stages, pluginDir: pluginDir,
            rulesDir: rulesDir,
            availableFields: availableFields
        )
        try wizard.run()
    }
}
