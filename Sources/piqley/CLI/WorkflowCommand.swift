import ArgumentParser
import Foundation
import PiqleyCore

struct WorkflowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Manage workflows",
        subcommands: [
            EditSubcommand.self, CreateSubcommand.self,
            CloneSubcommand.self, DeleteSubcommand.self,
            AddPluginSubcommand.self, RemovePluginSubcommand.self,
            OpenSubcommand.self, ConfigSubcommand.self,
        ]
    )

    /// Load the stage registry, discover plugins, and persist any auto-registered stages.
    static func loadRegistryAndPlugins() throws -> (registry: StageRegistry, plugins: [LoadedPlugin]) {
        let stagesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.stages)
        var registry = try StageRegistry.load(from: stagesDir)
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        let discovery = PluginDiscovery(pluginsDirectory: pluginsDir, registry: registry)
        let (plugins, updatedRegistry) = try discovery.loadManifests()
        registry = updatedRegistry
        try registry.save(to: stagesDir)
        return (registry, plugins)
    }

    // MARK: - Edit

    struct EditSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit a workflow with an interactive wizard"
        )

        @Argument(help: "Workflow name (opens workflow list if omitted)")
        var name: String?

        func run() throws {
            let (registry, plugins) = try WorkflowCommand.loadRegistryAndPlugins()

            if let name {
                guard WorkflowStore.exists(name: name) else {
                    throw CleanError("Workflow '\(name)' not found")
                }
                let workflow = try WorkflowStore.load(name: name)
                let wizard = ConfigWizard(workflow: workflow, discoveredPlugins: plugins, registry: registry)
                wizard.run()
            } else {
                let wizard = WorkflowListWizard(discoveredPlugins: plugins, registry: registry)
                wizard.run()
            }
        }
    }

    // MARK: - Create

    struct CreateSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new workflow"
        )

        @Argument(help: "Workflow name (prompted if omitted)")
        var name: String?

        func run() throws {
            let (registry, plugins) = try WorkflowCommand.loadRegistryAndPlugins()

            let workflowName: String
            if let name {
                workflowName = name
            } else {
                print("Workflow name: ", terminator: "")
                guard let input = readLine(), !input.isEmpty else {
                    throw ValidationError("Workflow name is required")
                }
                workflowName = input
            }

            guard !WorkflowStore.exists(name: workflowName) else {
                throw CleanError("Workflow '\(workflowName)' already exists")
            }

            let workflow = Workflow.empty(name: workflowName, displayName: workflowName, activeStages: registry.executionOrder)
            try WorkflowStore.save(workflow)
            print("Created workflow '\(workflowName)'")

            let wizard = ConfigWizard(workflow: workflow, discoveredPlugins: plugins, registry: registry)
            wizard.run()
        }
    }

    // MARK: - Clone

    struct CloneSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clone",
            abstract: "Clone an existing workflow"
        )

        @Argument(help: "Source workflow name")
        var source: String

        @Argument(help: "Destination workflow name")
        var destination: String

        func run() throws {
            try WorkflowStore.clone(source: source, destination: destination)
            print("Cloned workflow '\(source)' to '\(destination)'")
        }
    }

    // MARK: - Delete

    struct DeleteSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a workflow"
        )

        @Argument(help: "Workflow name")
        var name: String

        @Flag(help: "Skip confirmation prompt")
        var force = false

        func run() throws {
            guard WorkflowStore.exists(name: name) else {
                throw CleanError("Workflow '\(name)' not found")
            }

            if !force {
                print("Delete workflow '\(name)'? [y/N] ", terminator: "")
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else {
                    print("Cancelled.")
                    return
                }
            }

            try WorkflowStore.delete(name: name)
            print("Deleted workflow '\(name)'")

            // Prune orphaned secrets after workflow deletion
            let pruned = try SecretPruner.prune(
                configStore: .default,
                secretStore: makeDefaultSecretStore()
            )
            if !pruned.isEmpty {
                print("Pruned \(pruned.count) orphaned secret(s).")
            }
        }
    }

    // MARK: - Open

    struct OpenSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a workflow file in your editor"
        )

        @Argument(help: "Workflow name")
        var name: String

        func run() throws {
            let path = WorkflowStore.fileURL(name: name).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw CleanError("Workflow '\(name)' not found at \(path)")
            }
            try openInEditor(path)
        }
    }

    // MARK: - Add Plugin

    struct AddPluginSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-plugin",
            abstract: "Add a plugin to a workflow's pipeline stage"
        )

        @Argument(help: "Workflow name")
        var workflowName: String

        @Argument(help: "Plugin identifier")
        var pluginIdentifier: String

        @Argument(help: "Pipeline stage (any active or available stage name)")
        var stage: String

        @Option(help: "Position in the stage (0-based index, appends if omitted)")
        var position: Int?

        func run() throws {
            var workflow = try WorkflowStore.load(name: workflowName)
            let (registry, plugins) = try WorkflowCommand.loadRegistryAndPlugins()

            try PipelineEditor.validateAdd(
                pluginId: pluginIdentifier, stage: stage,
                workflow: workflow, discoveredPlugins: plugins,
                registry: registry
            )

            var list = workflow.pipeline[stage] ?? []
            if let pos = position, pos >= 0, pos <= list.count {
                list.insert(pluginIdentifier, at: pos)
            } else {
                list.append(pluginIdentifier)
            }
            workflow.pipeline[stage] = list
            try WorkflowStore.save(workflow)

            // Seed rules for this plugin if not already seeded
            let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
                .appendingPathComponent(pluginIdentifier)
            try? WorkflowStore.seedRules(
                workflowName: workflowName,
                pluginIdentifier: pluginIdentifier,
                pluginDirectory: pluginDir
            )

            print("Added '\(pluginIdentifier)' to \(stage) in workflow '\(workflowName)'")
        }
    }

    // MARK: - Remove Plugin

    struct RemovePluginSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove-plugin",
            abstract: "Remove a plugin from a workflow's pipeline stage"
        )

        @Argument(help: "Workflow name")
        var workflowName: String

        @Argument(help: "Plugin identifier")
        var pluginIdentifier: String

        @Argument(help: "Pipeline stage (any active or available stage name)")
        var stage: String

        func run() throws {
            var workflow = try WorkflowStore.load(name: workflowName)
            let (registry, plugins) = try WorkflowCommand.loadRegistryAndPlugins()

            try PipelineEditor.validateRemove(
                pluginId: pluginIdentifier, stage: stage,
                workflow: workflow, registry: registry
            )

            let dependents = PipelineEditor.dependents(
                of: pluginIdentifier, in: workflow, discoveredPlugins: plugins
            )
            if !dependents.isEmpty {
                print("Warning: The following plugins depend on '\(pluginIdentifier)': \(dependents.joined(separator: ", "))")
            }

            var list = workflow.pipeline[stage] ?? []
            list.removeAll { $0 == pluginIdentifier }
            workflow.pipeline[stage] = list
            try WorkflowStore.save(workflow)

            // Clean up rules if plugin is no longer in any stage
            let allPipelinePlugins = Set(workflow.pipeline.values.flatMap(\.self))
            if !allPipelinePlugins.contains(pluginIdentifier) {
                try? WorkflowStore.removePluginRules(
                    workflowName: workflowName, pluginIdentifier: pluginIdentifier
                )
            }

            print("Removed '\(pluginIdentifier)' from \(stage) in workflow '\(workflowName)'")
        }
    }
}
