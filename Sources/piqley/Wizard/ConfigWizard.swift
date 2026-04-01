import Foundation
import PiqleyCore

final class ConfigWizard {
    var workflow: Workflow
    let discoveredPlugins: [LoadedPlugin]
    let terminal: RawTerminal
    var modified = false
    var savedAt: Date?
    /// Tracks plugins marked for removal, keyed by "stage:pluginIdentifier"
    var removedPlugins: Set<String> = []

    /// Identifiers of plugins that exist on disk.
    let discoveredIdentifiers: Set<String>

    var registry: StageRegistry

    let pluginsDirectory: URL

    init(
        workflow: Workflow,
        discoveredPlugins: [LoadedPlugin],
        registry: StageRegistry,
        pluginsDirectory: URL = PipelineOrchestrator.defaultPluginsDirectory
    ) {
        self.workflow = workflow
        self.discoveredPlugins = discoveredPlugins
        self.registry = registry
        self.pluginsDirectory = pluginsDirectory
        discoveredIdentifiers = Set(discoveredPlugins.map(\.identifier))
        terminal = RawTerminal()

        // Scan workflow rules dirs for stages not yet in the registry
        WorkflowStore.scanAndRegisterStages(workflowName: workflow.name, registry: &self.registry)
    }

    func run() {
        defer { terminal.restore() }
        stageSelect()
    }

    // MARK: - Stage Select

    /// Selectable items on the stage selector: 4 stages + "List all Plugins"
    enum StageMenuItem {
        case stage(String)
        case allPlugins
    }

    private func stageSelect() {
        var cursor = 0

        while true {
            let stages = registry.executionOrder.filter { !StandardHook.requiredStageNames.contains($0) }
            let menuItems: [StageMenuItem] = stages.map { .stage($0) } + [.allPlugins]
            cursor = min(cursor, menuItems.count - 1)
            drawStageScreen(stages: stages, menuItems: menuItems, cursor: cursor)

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(menuItems.count - 1, cursor + 1)
            case .enter:
                switch menuItems[cursor] {
                case let .stage(name):
                    pluginList(stageName: name)
                case .allPlugins:
                    showAllPlugins()
                }
            case .char("a"):
                addStage()
            case .char("u"):
                duplicateStage(at: cursor)
            case .char("v"):
                activateStage()
            case .char("x"):
                if cursor < stages.count {
                    removeStage(stages[cursor])
                }
            case .char("n"):
                if cursor < stages.count {
                    renameStage(stages[cursor])
                }
            case .char("r"):
                if cursor < stages.count, stages.count > 1 {
                    if let newPos = reorderStage(startIndex: cursor) {
                        cursor = newPos
                    }
                }
            case .char("s"):
                save()
            case .escape, .ctrlC:
                promptUnsavedAndExit()
                if shouldQuit { return }
            default: break
            }
        }
    }

    // MARK: - Plugin List

    private func removalKey(stage: String, plugin: String) -> String {
        "\(stage):\(plugin)"
    }

    private func pluginList(stageName: String) {
        var cursor = 0

        while true {
            let plugins = workflow.pipeline[stageName] ?? []
            let activeItems: [String] = plugins.isEmpty
                ? ["(no plugins)"]
                : plugins.map { plugin in
                    let key = removalKey(stage: stageName, plugin: plugin)
                    if removedPlugins.contains(key) {
                        return "\(ANSI.dim)" + strikethrough(plugin) + "\(ANSI.reset)"
                    }
                    if !discoveredIdentifiers.contains(plugin) {
                        return "\(plugin)  \(ANSI.red)missing\(ANSI.reset)"
                    }
                    return plugin
                }

            let inactivePlugins = inactivePluginIdentifiers(for: stageName, excluding: Set(plugins))
            let (displayItems, dividerIndex) = buildDisplayItems(active: activeItems, inactive: inactivePlugins)

            let inactiveStartIndex = dividerIndex.map { $0 + 1 } ?? Int.max
            let isOnInactive = cursor >= inactiveStartIndex && cursor < displayItems.count

            let isCurrentRemoved = !plugins.isEmpty && cursor < plugins.count
                && removedPlugins.contains(removalKey(stage: stageName, plugin: plugins[cursor]))
            let removeLabel = isCurrentRemoved ? "d undelete" : "d remove"

            terminal.drawScreen(
                title: "\(stageName) plugins",
                items: displayItems,
                cursor: cursor,
                footer: footerWithSaveIndicator("\u{2191}\u{2193} navigate  \u{23CE} rules  a add  \(removeLabel)  r reorder  s save  Esc back")
            )

            let key = readKeyWithSaveTimeout()
            switch key {
            case .timeout: continue
            case .cursorUp, .cursorDown, .pageUp, .pageDown:
                cursor = navigateCursor(key: key, cursor: cursor, itemCount: displayItems.count, dividerIndex: dividerIndex)
            case .enter where isOnInactive, .char("a") where isOnInactive:
                activateInactivePlugin(inactivePlugins[cursor - inactiveStartIndex], stageName: stageName)
                cursor = 0
            case .enter:
                if !plugins.isEmpty, cursor < plugins.count {
                    let pluginID = plugins[cursor]
                    let rmKey = removalKey(stage: stageName, plugin: pluginID)
                    if !removedPlugins.contains(rmKey), discoveredIdentifiers.contains(pluginID) {
                        editRulesForPlugin(pluginID, inStage: stageName)
                    }
                }
            case .char("a"):
                addPlugin(stageName: stageName)
            case .char("d"):
                togglePluginRemoval(plugins: plugins, cursor: cursor, stageName: stageName)
            case .char("r"):
                if !plugins.isEmpty, cursor < plugins.count, plugins.count > 1 {
                    if let newPos = interactiveReorder(stageName: stageName, startIndex: cursor) {
                        cursor = newPos
                    }
                }
            case .char("s"):
                save()
            case .escape:
                return
            default: break
            }
        }
    }

    private func inactivePluginIdentifiers(for stageName: String, excluding currentPlugins: Set<String>) -> [String] {
        discoveredPlugins
            .filter { plugin in
                guard !currentPlugins.contains(plugin.identifier) else { return false }
                return plugin.stages.keys.contains(stageName)
                    || WorkflowStore.hasStageFile(
                        workflowName: workflow.name,
                        pluginIdentifier: plugin.identifier,
                        stageName: stageName
                    )
            }
            .map(\.identifier)
            .sorted()
    }

    private func buildDisplayItems(active: [String], inactive: [String]) -> (items: [String], dividerIndex: Int?) {
        var items = active
        guard !inactive.isEmpty else { return (items, nil) }
        let dividerIndex = items.count
        items.append("\(ANSI.dim)── inactive ──\(ANSI.reset)")
        items += inactive.map { "\(ANSI.dim)\(ANSI.italic)\($0)\(ANSI.reset)" }
        return (items, dividerIndex)
    }

    private func navigateCursor(key: Key, cursor: Int, itemCount: Int, dividerIndex: Int?) -> Int {
        let maxIdx = max(itemCount - 1, 0)
        var newCursor: Int
        switch key {
        case .cursorUp: newCursor = max(0, cursor - 1)
        case .cursorDown: newCursor = min(maxIdx, cursor + 1)
        case .pageUp: newCursor = max(0, cursor - 10)
        case .pageDown: newCursor = min(maxIdx, cursor + 10)
        default: return cursor
        }
        if newCursor == dividerIndex {
            let direction = (key == .cursorUp || key == .pageUp) ? -1 : 1
            newCursor = max(0, min(maxIdx, newCursor + direction))
        }
        return newCursor
    }

    private func togglePluginRemoval(plugins: [String], cursor: Int, stageName: String) {
        guard !plugins.isEmpty, cursor < plugins.count else { return }
        let rmKey = removalKey(stage: stageName, plugin: plugins[cursor])
        if removedPlugins.contains(rmKey) {
            removedPlugins.remove(rmKey)
        } else {
            removedPlugins.insert(rmKey)
            modified = true
        }
    }

    // MARK: - Add Plugin

    private func addPlugin(stageName: String) {
        let currentPlugins = Set(workflow.pipeline[stageName] ?? [])
        let available = discoveredPlugins
            .filter { !currentPlugins.contains($0.identifier) }
            .map(\.identifier)
            .sorted()

        if available.isEmpty {
            terminal.showMessage("No plugins available to add.")
            return
        }

        guard let idx = terminal.selectFromFilterableList(title: "Add plugin to \(stageName)", items: available) else {
            return
        }

        var list = workflow.pipeline[stageName] ?? []
        list.append(available[idx])
        workflow.pipeline[stageName] = list

        // Seed rules for this plugin if not already seeded
        let pluginDir = pluginsDirectory.appendingPathComponent(available[idx])
        try? WorkflowStore.seedRules(
            workflowName: workflow.name,
            pluginIdentifier: available[idx],
            pluginDirectory: pluginDir
        )

        modified = true
    }

    private func activateInactivePlugin(_ identifier: String, stageName: String) {
        var list = workflow.pipeline[stageName] ?? []
        list.append(identifier)
        workflow.pipeline[stageName] = list
        let pluginDir = pluginsDirectory.appendingPathComponent(identifier)
        try? WorkflowStore.seedRules(
            workflowName: workflow.name,
            pluginIdentifier: identifier,
            pluginDirectory: pluginDir
        )
        modified = true
    }

    // MARK: - Interactive Reorder

    private func interactiveReorder(stageName: String, startIndex: Int) -> Int? {
        var position = startIndex
        let originalList = workflow.pipeline[stageName] ?? []
        let count = originalList.count

        while true {
            let plugins = workflow.pipeline[stageName] ?? []
            let items: [String] = plugins.enumerated().map { idx, plugin in
                let key = removalKey(stage: stageName, plugin: plugin)
                let missing = !discoveredIdentifiers.contains(plugin)
                let suffix = missing ? "  \(ANSI.red)missing\(ANSI.reset)" : ""
                if idx == position {
                    return "  \(ANSI.italic)\(plugin)\(ANSI.reset)\(suffix)"
                }
                if removedPlugins.contains(key) {
                    return "\(ANSI.dim)" + strikethrough(plugin) + "\(ANSI.reset)"
                }
                return "\(plugin)\(suffix)"
            }

            terminal.drawScreen(
                title: "\(stageName) plugins \u{2014} reordering",
                items: items,
                cursor: position,
                footer: "\u{2191}\u{2193} move  \u{23CE} confirm  Esc cancel"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp:
                if position > 0 {
                    var list = workflow.pipeline[stageName] ?? []
                    list.swapAt(position, position - 1)
                    workflow.pipeline[stageName] = list
                    position -= 1
                }
            case .cursorDown:
                if position < count - 1 {
                    var list = workflow.pipeline[stageName] ?? []
                    list.swapAt(position, position + 1)
                    workflow.pipeline[stageName] = list
                    position += 1
                }
            case .enter:
                if position != startIndex { modified = true }
                return position
            case .escape:
                workflow.pipeline[stageName] = originalList
                return nil
            default: break
            }
        }
    }

    // MARK: - Save / Quit

    private func save() {
        applyRemovals()
        do {
            try WorkflowStore.save(workflow)
            let stagesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(PiqleyPath.stages)
            try registry.save(to: stagesDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    func footerWithSaveIndicator(_ base: String) -> String {
        if let savedAt, Date().timeIntervalSince(savedAt) < 2 {
            return "\(ANSI.green)\(ANSI.bold)Saved\(ANSI.reset)  \(base)"
        }
        return base
    }

    func readKeyWithSaveTimeout() -> Key {
        if let savedAt {
            let remaining = 2.0 - Date().timeIntervalSince(savedAt)
            if remaining > 0 {
                let key = terminal.readKey(timeoutMs: Int32(remaining * 1000))
                if key == .timeout {
                    self.savedAt = nil
                    return .timeout
                }
                return key
            }
            self.savedAt = nil
        }
        return terminal.readKey()
    }

    private func applyRemovals() {
        var removedIdentifiers: Set<String> = []
        for key in removedPlugins {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let stage = String(parts[0])
            let plugin = String(parts[1])
            workflow.pipeline[stage]?.removeAll { $0 == plugin }
            removedIdentifiers.insert(plugin)
        }
        removedPlugins.removeAll()

        // Clean up rules for plugins no longer in any stage
        let allPipelinePlugins = Set(workflow.pipeline.values.flatMap(\.self))
        for identifier in removedIdentifiers where !allPipelinePlugins.contains(identifier) {
            try? WorkflowStore.removePluginRules(
                workflowName: workflow.name, pluginIdentifier: identifier
            )
        }
    }

    private var shouldQuit = false

    private func quit() {
        terminal.restore()
        shouldQuit = true
    }

    private func promptUnsavedAndExit() {
        if !modified { quit(); return }

        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)You have unsaved changes.\(ANSI.reset)"
        buf += ANSI.moveTo(row: 3, col: 1)
        buf += "  s  Save and quit"
        buf += ANSI.moveTo(row: 4, col: 1)
        buf += "  d  Discard and quit"
        buf += ANSI.moveTo(row: 5, col: 1)
        buf += "  Esc  Cancel (go back)"
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)s save  d discard  Esc cancel\(ANSI.reset)"
        terminal.write(buf)

        while true {
            let key = terminal.readKey()
            switch key {
            case .char("s"):
                save()
                quit()
                return
            case .char("d"):
                quit()
                return
            case .escape:
                return
            default: break
            }
        }
    }

    // MARK: - Helpers

    private func strikethrough(_ text: String) -> String {
        var result = ""
        for char in text {
            result.append(char)
            result.append("\u{0336}")
        }
        return result
    }
}
