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
        if let firstArg, let pluginID = secondArg {
            // Explicit: piqley rules <workflow> <plugin>
            return (firstArg, pluginID)
        }

        if let firstArg {
            return try resolveSingleArg(firstArg)
        }

        // No args: select workflow then plugin interactively
        return try resolveNoArgs()
    }

    private func resolveSingleArg(_ arg: String) throws -> (workflowName: String, pluginID: String) {
        // Check workflow first, then plugin
        if WorkflowStore.exists(name: arg) {
            let workflow = try WorkflowStore.load(name: arg)
            let plugins = pipelinePlugins(workflow)
            guard !plugins.isEmpty else {
                throw CleanError("Workflow '\(arg)' has no plugins in its pipeline.")
            }
            if plugins.count == 1 {
                return (arg, plugins[0])
            }
            let pluginID = try selectInteractively(
                title: "Select plugin (\(arg))",
                items: plugins
            )
            return (arg, pluginID)
        }

        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        let isPlugin = FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent(arg).path
        )

        if isPlugin {
            let allWorkflows = try WorkflowStore.loadAll()
            let matching = allWorkflows.filter { workflow in
                workflow.pipeline.values.flatMap(\.self).contains(arg)
            }
            guard !matching.isEmpty else {
                throw CleanError("Plugin '\(arg)' is not in any workflow's pipeline.")
            }
            if matching.count == 1 {
                return (matching[0].name, arg)
            }
            let workflowName = try selectInteractively(
                title: "Select workflow for '\(arg)'",
                items: matching.map(\.name)
            )
            return (workflowName, arg)
        }

        throw CleanError("'\(arg)' is not a known workflow or installed plugin.")
    }

    private func resolveNoArgs() throws -> (workflowName: String, pluginID: String) {
        let workflowNames = try WorkflowStore.list()
        guard !workflowNames.isEmpty else {
            throw CleanError("No workflows found. Run 'piqley setup' first.")
        }

        let workflowName: String = if workflowNames.count == 1 {
            workflowNames[0]
        } else {
            try selectInteractively(
                title: "Select workflow",
                items: workflowNames
            )
        }

        let workflow = try WorkflowStore.load(name: workflowName)
        let plugins = pipelinePlugins(workflow)
        guard !plugins.isEmpty else {
            throw CleanError("Workflow '\(workflowName)' has no plugins in its pipeline.")
        }

        if plugins.count == 1 {
            return (workflowName, plugins[0])
        }

        let pluginID = try selectInteractively(
            title: "Select plugin (\(workflowName))",
            items: plugins
        )
        return (workflowName, pluginID)
    }

    // MARK: - Helpers

    private func pipelinePlugins(_ workflow: Workflow) -> [String] {
        Array(Set(workflow.pipeline.values.flatMap(\.self))).sorted()
    }

    private func selectInteractively(title: String, items: [String]) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CleanError(
                "Multiple options available but stdin is not a terminal. "
                    + "Specify explicitly: piqley plugin rules <workflow> <plugin>"
            )
        }
        let terminal = RawTerminal()
        defer { terminal.restore() }
        guard let index = terminal.selectFromList(title: title, items: items) else {
            throw ExitCode.success
        }
        return items[index]
    }
}
