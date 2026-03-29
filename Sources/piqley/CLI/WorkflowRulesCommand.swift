import ArgumentParser
import Foundation
import Logging
import PiqleyCore

extension WorkflowCommand {
    struct RulesSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rules",
            abstract: "Interactively edit rules for a plugin within a workflow."
        )

        @Argument(help: "The plugin identifier (or workflow name if two arguments given).")
        var firstArg: String?

        @Argument(help: "The plugin identifier when first argument is a workflow name.")
        var secondArg: String?

        func run() throws {
            let (registry, discoveredPlugins) = try WorkflowCommand.loadRegistryAndPlugins()
            let (workflowName, pluginID, isInactive) = try resolveArguments(
                discoveredPlugins: discoveredPlugins
            )

            var workflow = try WorkflowStore.load(name: workflowName)

            if isInactive {
                try activatePlugin(
                    pluginID, in: &workflow,
                    registry: registry, discoveredPlugins: discoveredPlugins
                )
            } else {
                // Verify plugin is in the workflow's pipeline
                let plugins = Set(workflow.pipeline.values.flatMap(\.self))
                guard plugins.contains(pluginID) else {
                    throw CleanError("Plugin '\(pluginID)' is not in workflow '\(workflowName)'")
                }
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
            if !manifest.fields.isEmpty {
                allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: manifest.fields))
            }

            // Build context and launch wizard
            let availableFields = FieldDiscovery.buildAvailableFields(dependencies: allDeps)
            let context = RuleEditingContext(
                availableFields: availableFields,
                pluginIdentifier: pluginID,
                stages: stages
            )

            let wizard = RulesWizard(context: context, rulesDir: rulesDir, workflowName: workflowName)
            try wizard.run()
        }

        // MARK: - Argument Resolution

        private func resolveArguments(
            discoveredPlugins: [LoadedPlugin]
        ) throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
            let resolver = PluginWorkflowResolver(
                firstArg: firstArg, secondArg: secondArg,
                usageHint: "piqley workflow rules",
                discoveredPlugins: discoveredPlugins
            )
            return try resolver.resolve()
        }

        // MARK: - Inactive Plugin Activation

        private func activatePlugin(
            _ pluginID: String,
            in workflow: inout Workflow,
            registry: StageRegistry,
            discoveredPlugins: [LoadedPlugin]
        ) throws {
            guard let plugin = discoveredPlugins.first(where: { $0.identifier == pluginID }) else {
                throw CleanError("Plugin '\(pluginID)' is not installed.")
            }

            let supportedStages = registry.executionOrder.filter { plugin.stages.keys.contains($0) }
            guard !supportedStages.isEmpty else {
                throw CleanError(
                    "Plugin '\(pluginID)' has no stages matching the active stage registry."
                )
            }

            let selectedStage: String
            if supportedStages.count == 1 {
                selectedStage = supportedStages[0]
            } else {
                guard isatty(STDIN_FILENO) != 0 else {
                    throw CleanError(
                        "Plugin '\(pluginID)' supports multiple stages but stdin is not a terminal. "
                            + "Use 'piqley workflow add-plugin' instead."
                    )
                }
                let terminal = RawTerminal()
                defer { terminal.restore() }
                guard let idx = terminal.selectFromList(
                    title: "Add '\(pluginID)' to which stage?",
                    items: supportedStages
                ) else {
                    throw ExitCode.success
                }
                selectedStage = supportedStages[idx]
            }

            var list = workflow.pipeline[selectedStage] ?? []
            list.append(pluginID)
            workflow.pipeline[selectedStage] = list
            try WorkflowStore.save(workflow)

            let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
                .appendingPathComponent(pluginID)
            try? WorkflowStore.seedRules(
                workflowName: workflow.name,
                pluginIdentifier: pluginID,
                pluginDirectory: pluginDir
            )
        }
    }
}
