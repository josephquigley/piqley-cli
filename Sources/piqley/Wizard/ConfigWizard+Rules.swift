import Foundation
import Logging
import PiqleyCore

extension ConfigWizard {
    /// Launch a nested RulesWizard for a specific plugin scoped to a single stage.
    func editRulesForPlugin(_ pluginID: String, inStage stageName: String) {
        guard let plugin = discoveredPlugins.first(where: { $0.identifier == pluginID }) else {
            terminal.showMessage("Plugin '\(pluginID)' not found.")
            return
        }

        // Ensure rules are seeded for this plugin
        try? WorkflowStore.seedRules(
            workflowName: workflow.name,
            pluginIdentifier: pluginID,
            pluginDirectory: plugin.directory
        )

        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: workflow.name, pluginIdentifier: pluginID
        )

        // Load stages from workflow rules dir
        let knownHooks = registry.allKnownNames
        var (stages, _) = PluginDiscovery.loadStages(
            from: rulesDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.rules")
        )

        // Ensure the target stage exists
        if stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Discover upstream fields
        let rulesBaseDir = WorkflowStore.rulesDirectory(name: workflow.name)
        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: workflow.pipeline,
            targetPlugin: pluginID,
            stageOrder: registry.executionOrder,
            rulesBaseDir: rulesBaseDir
        )

        var allDeps = deps
        if !plugin.manifest.fields.isEmpty {
            allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: plugin.manifest.fields))
        }

        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: allDeps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: pluginID,
            stages: stages
        )

        // Restore ConfigWizard's terminal before launching nested wizard
        terminal.restore()

        let wizard = RulesWizard(context: context, rulesDir: rulesDir, workflowName: workflow.name)
        wizard.runForStage(stageName)

        // Re-enter ConfigWizard's terminal
        terminal.reenter()
    }
}
