import ArgumentParser
import Foundation
import PiqleyCore

struct PluginWorkflowResolver {
    let firstArg: String?
    let secondArg: String?
    /// Used in non-interactive error messages, e.g. "piqley plugin command <workflow> <plugin>"
    let usageHint: String
    let workflowsRoot: URL?
    let pluginsDirectory: URL

    init(
        firstArg: String?, secondArg: String?,
        usageHint: String,
        workflowsRoot: URL? = nil,
        pluginsDirectory: URL = PipelineOrchestrator.defaultPluginsDirectory
    ) {
        self.firstArg = firstArg
        self.secondArg = secondArg
        self.usageHint = usageHint
        self.workflowsRoot = workflowsRoot
        self.pluginsDirectory = pluginsDirectory
    }

    func resolve() throws -> (workflowName: String, pluginID: String) {
        if let firstArg, let pluginID = secondArg {
            return (firstArg, pluginID)
        }

        if let firstArg {
            return try resolveSingleArg(firstArg)
        }

        return try resolveNoArgs()
    }

    // MARK: - Private

    private func resolveSingleArg(_ arg: String) throws -> (workflowName: String, pluginID: String) {
        if WorkflowStore.exists(name: arg, root: workflowsRoot) {
            let workflow = try WorkflowStore.load(name: arg, root: workflowsRoot)
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

        let isPlugin = FileManager.default.fileExists(
            atPath: pluginsDirectory.appendingPathComponent(arg).path
        )

        if isPlugin {
            let allWorkflows = try WorkflowStore.loadAll(root: workflowsRoot)
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
        let workflowNames = try WorkflowStore.list(root: workflowsRoot)
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

        let workflow = try WorkflowStore.load(name: workflowName, root: workflowsRoot)
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

    private func pipelinePlugins(_ workflow: Workflow) -> [String] {
        Array(Set(workflow.pipeline.values.flatMap(\.self))).sorted()
    }

    private func selectInteractively(title: String, items: [String]) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CleanError(
                "Multiple options available but stdin is not a terminal. "
                    + "Specify explicitly: \(usageHint) <workflow> <plugin>"
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
