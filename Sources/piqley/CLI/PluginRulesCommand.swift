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
    var firstArg: String?

    @Argument(help: "The plugin identifier when first argument is a workflow name.")
    var secondArg: String?

    func run() throws {
        let (workflowName, pluginID) = try resolveArguments()

        // Load workflow
        let workflow = try WorkflowStore.load(name: workflowName)

        // Verify plugin is in the workflow's pipeline
        let plugins = Set(workflow.pipeline.values.flatMap(\.self))
        guard plugins.contains(pluginID) else {
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
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)

        guard manifest.type == .mutable else {
            throw CleanError(
                "'\(manifest.name)' is a static plugin and cannot be modified. "
                    + "Config values can be changed with 'piqley plugin config'."
            )
        }

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

        // Build context and launch wizard
        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: allDeps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: pluginID,
            stages: stages
        )

        let wizard = RulesWizard(context: context, rulesDir: rulesDir)
        try wizard.run()
    }

    // MARK: - Argument Resolution

    private func resolveArguments() throws -> (workflowName: String, pluginID: String) {
        let resolver = PluginWorkflowResolver(
            firstArg: firstArg, secondArg: secondArg,
            usageHint: "piqley plugin rules"
        )
        return try resolver.resolve()
    }
}
