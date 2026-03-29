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
    let discoveredPlugins: [LoadedPlugin]

    init(
        firstArg: String?, secondArg: String?,
        usageHint: String,
        workflowsRoot: URL? = nil,
        pluginsDirectory: URL = PipelineOrchestrator.defaultPluginsDirectory,
        discoveredPlugins: [LoadedPlugin] = []
    ) {
        self.firstArg = firstArg
        self.secondArg = secondArg
        self.usageHint = usageHint
        self.workflowsRoot = workflowsRoot
        self.pluginsDirectory = pluginsDirectory
        self.discoveredPlugins = discoveredPlugins
    }

    func resolve() throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
        if let firstArg, let pluginID = secondArg {
            let isInactive = try checkInactive(workflowName: firstArg, pluginID: pluginID)
            return (firstArg, pluginID, isInactive)
        }

        if let firstArg {
            return try resolveSingleArg(firstArg)
        }

        return try resolveNoArgs()
    }

    // MARK: - Private

    private func checkInactive(workflowName: String, pluginID: String) throws -> Bool {
        guard !discoveredPlugins.isEmpty else { return false }
        let workflow = try WorkflowStore.load(name: workflowName, root: workflowsRoot)
        let pipelineSet = Set(workflow.pipeline.values.flatMap(\.self))
        return !pipelineSet.contains(pluginID)
    }

    private func resolveSingleArg(_ arg: String) throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
        if WorkflowStore.exists(name: arg, root: workflowsRoot) {
            let workflow = try WorkflowStore.load(name: arg, root: workflowsRoot)
            let plugins = pipelinePlugins(workflow)
            let inactive = inactivePluginIdentifiers(workflow: workflow)

            if plugins.isEmpty, inactive.isEmpty {
                throw CleanError("Workflow '\(arg)' has no plugins in its pipeline.")
            }

            if plugins.count == 1, inactive.isEmpty {
                return (arg, plugins[0], false)
            }

            let (pluginID, isInactive) = try selectPluginInteractively(
                title: "Select plugin (\(arg))",
                active: plugins,
                inactive: inactive
            )
            return (arg, pluginID, isInactive)
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
                return (matching[0].name, arg, false)
            }
            let workflowName = try selectInteractively(
                title: "Select workflow for '\(arg)'",
                items: matching.map(\.name)
            )
            return (workflowName, arg, false)
        }

        throw CleanError("'\(arg)' is not a known workflow or installed plugin.")
    }

    private func resolveNoArgs() throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
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
        let inactive = inactivePluginIdentifiers(workflow: workflow)

        if plugins.isEmpty, inactive.isEmpty {
            throw CleanError("Workflow '\(workflowName)' has no plugins in its pipeline.")
        }

        if plugins.count == 1, inactive.isEmpty {
            return (workflowName, plugins[0], false)
        }

        let (pluginID, isInactive) = try selectPluginInteractively(
            title: "Select plugin (\(workflowName))",
            active: plugins,
            inactive: inactive
        )
        return (workflowName, pluginID, isInactive)
    }

    private func pipelinePlugins(_ workflow: Workflow) -> [String] {
        Array(Set(workflow.pipeline.values.flatMap(\.self))).sorted()
    }

    private func inactivePluginIdentifiers(workflow: Workflow) -> [String] {
        guard !discoveredPlugins.isEmpty else { return [] }
        let pipelineSet = Set(workflow.pipeline.values.flatMap(\.self))
        return discoveredPlugins
            .filter { !pipelineSet.contains($0.identifier) }
            .map(\.identifier)
            .sorted()
    }

    private func selectPluginInteractively(
        title: String, active: [String], inactive: [String]
    ) throws -> (pluginID: String, isInactive: Bool) {
        var items = active
        var dividerIndex: Int?
        if !inactive.isEmpty {
            dividerIndex = items.count
            items.append("\(ANSI.dim)\u{2500}\u{2500} inactive \u{2500}\u{2500}\(ANSI.reset)")
            items += inactive.map { "\(ANSI.dim)\(ANSI.italic)\($0)\(ANSI.reset)" }
        }

        guard isatty(STDIN_FILENO) != 0 else {
            throw CleanError(
                "Multiple options available but stdin is not a terminal. "
                    + "Specify explicitly: \(usageHint) <workflow> <plugin>"
            )
        }
        let terminal = RawTerminal()
        defer { terminal.restore() }

        guard let index = terminal.selectFromListWithDivider(
            title: title, items: items, dividerIndex: dividerIndex
        ) else {
            throw ExitCode.success
        }

        if let dividerIndex, index > dividerIndex {
            let inactiveIdx = index - dividerIndex - 1
            return (inactive[inactiveIdx], true)
        }
        return (active[index], false)
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
