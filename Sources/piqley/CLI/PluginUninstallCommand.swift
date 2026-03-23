import ArgumentParser
import Foundation
import PiqleyCore

extension PluginCommand {
    struct UninstallSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Uninstall a plugin by identifier"
        )

        @Argument(help: "Plugin identifier (reverse-TLD, e.g. com.example.myplugin)")
        var pluginIdentifier: String

        @Flag(help: "Force uninstall even if other plugins depend on this one")
        var force = false

        func run() throws {
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let pluginDir = pluginsDir.appendingPathComponent(pluginIdentifier)

            let workflows = try WorkflowStore.loadAll()
            let (_, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()

            let pluginLoaded = allPlugins.contains { $0.identifier == pluginIdentifier }
            let pluginDirExists = FileManager.default.fileExists(atPath: pluginDir.path)

            guard pluginLoaded || pluginDirExists else {
                throw CleanError("Plugin '\(pluginIdentifier)' is not installed")
            }

            // Check for dependent plugins across all workflows
            if pluginLoaded {
                var allDependents = Set<String>()
                for workflow in workflows {
                    let deps = PipelineEditor.dependents(
                        of: pluginIdentifier, in: workflow, discoveredPlugins: allPlugins
                    )
                    allDependents.formUnion(deps)
                }
                if !allDependents.isEmpty, !force {
                    let list = allDependents.sorted().joined(separator: ", ")
                    throw CleanError(
                        "Cannot uninstall '\(pluginIdentifier)': the following plugins depend on it: \(list)\n"
                            + "Use --force to uninstall anyway."
                    )
                }
            }

            // Check for workflow usage
            let affectedWorkflows = workflows.filter { workflow in
                workflow.pipeline.values.flatMap(\.self).contains(pluginIdentifier)
            }
            if !affectedWorkflows.isEmpty, !force {
                let names = affectedWorkflows.map(\.name).joined(separator: ", ")
                print(
                    "This plugin is used in \(affectedWorkflows.count) workflow(s): \(names). Continue? [y/N] ",
                    terminator: ""
                )
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else {
                    print("Cancelled.")
                    return
                }
            }

            // Delete plugin directory first (before modifying workflows)
            try FileManager.default.removeItem(at: pluginDir)

            // Remove from all workflow pipeline configs
            var modifiedWorkflows: [String] = []
            for var workflow in affectedWorkflows {
                for (stage, plugins) in workflow.pipeline {
                    workflow.pipeline[stage] = plugins.filter { $0 != pluginIdentifier }
                }
                try WorkflowStore.save(workflow)
                modifiedWorkflows.append(workflow.name)
            }

            if !modifiedWorkflows.isEmpty {
                let names = modifiedWorkflows.joined(separator: ", ")
                print("Removed '\(pluginIdentifier)' from workflow(s): \(names)")
            }

            // Delete base config file
            let configStore = BasePluginConfigStore.default
            try configStore.delete(for: pluginIdentifier)

            // Prune orphaned secrets
            let secretStore = makeDefaultSecretStore()
            let pruned = try SecretPruner.prune(
                configStore: configStore,
                secretStore: secretStore
            )
            if !pruned.isEmpty {
                print("Pruned \(pruned.count) orphaned secret(s).")
            }

            print("Uninstalled '\(pluginIdentifier)'")
        }
    }
}
