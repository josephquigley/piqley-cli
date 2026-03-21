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
            OpenSubcommand.self,
        ]
    )

    // MARK: - Edit

    struct EditSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit a workflow with an interactive wizard"
        )

        @Argument(help: "Workflow name (opens workflow list if omitted)")
        var name: String?

        func run() throws {
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            if let name {
                guard WorkflowStore.exists(name: name) else {
                    throw ValidationError("Workflow '\(name)' not found")
                }
                let workflow = try WorkflowStore.load(name: name)
                let wizard = ConfigWizard(workflow: workflow, discoveredPlugins: plugins)
                wizard.run()
            } else {
                let wizard = WorkflowListWizard(discoveredPlugins: plugins)
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
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

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
                throw ValidationError("Workflow '\(workflowName)' already exists")
            }

            let workflow = Workflow.empty(name: workflowName, displayName: workflowName)
            try WorkflowStore.save(workflow)
            print("Created workflow '\(workflowName)'")

            let wizard = ConfigWizard(workflow: workflow, discoveredPlugins: plugins)
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
                throw ValidationError("Workflow '\(name)' not found")
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
                throw ValidationError("Workflow '\(name)' not found at \(path)")
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

        @Argument(help: "Pipeline stage (pre-process, post-process, publish, post-publish)")
        var stage: String

        @Option(help: "Position in the stage (0-based index, appends if omitted)")
        var position: Int?

        func run() throws {
            var workflow = try WorkflowStore.load(name: workflowName)
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            try PipelineEditor.validateAdd(
                pluginId: pluginIdentifier, stage: stage,
                workflow: workflow, discoveredPlugins: plugins
            )

            var list = workflow.pipeline[stage] ?? []
            if let pos = position, pos >= 0, pos <= list.count {
                list.insert(pluginIdentifier, at: pos)
            } else {
                list.append(pluginIdentifier)
            }
            workflow.pipeline[stage] = list
            try WorkflowStore.save(workflow)

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

        @Argument(help: "Pipeline stage (pre-process, post-process, publish, post-publish)")
        var stage: String

        func run() throws {
            var workflow = try WorkflowStore.load(name: workflowName)
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            try PipelineEditor.validateRemove(
                pluginId: pluginIdentifier, stage: stage, workflow: workflow
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

            print("Removed '\(pluginIdentifier)' from \(stage) in workflow '\(workflowName)'")
        }
    }
}
