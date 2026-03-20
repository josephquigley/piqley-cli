import Foundation
import PiqleyCore

final class ConfigWizard {
    var config: AppConfig
    let discoveredPlugins: [LoadedPlugin]
    let terminal: RawTerminal
    var modified = false
    /// Tracks plugins marked for removal, keyed by "stage:pluginIdentifier"
    var removedPlugins: Set<String> = []

    init(config: AppConfig, discoveredPlugins: [LoadedPlugin]) {
        self.config = config
        self.discoveredPlugins = discoveredPlugins
        terminal = RawTerminal()
    }

    func run() {
        defer { terminal.restore() }
        stageSelect()
    }

    // MARK: - Stage Select

    private func stageSelect() {
        let stages = Hook.canonicalOrder.map(\.rawValue)
        var cursor = 0

        while true {
            let items = stages.map { stage in
                let plugins = config.pipeline[stage] ?? []
                let count = plugins.count
                let label = count == 1 ? "plugin" : "plugins"
                return "\(stage) (\(count) \(label))"
            }

            terminal.drawScreen(
                title: "Edit Pipeline",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} select  s save  Esc quit"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(stages.count - 1, cursor + 1)
            case .enter:
                pluginList(stageName: stages[cursor])
            case .char("s"):
                save()
            case .escape, .ctrlC:
                promptUnsavedAndExit()
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
            let plugins = config.pipeline[stageName] ?? []
            let items: [String] = plugins.isEmpty
                ? ["(no plugins)"]
                : plugins.map { plugin in
                    let key = removalKey(stage: stageName, plugin: plugin)
                    if removedPlugins.contains(key) {
                        return "\(ANSI.dim)" + strikethrough(plugin) + "\(ANSI.reset)"
                    }
                    return plugin
                }

            let isCurrentRemoved = !plugins.isEmpty && cursor < plugins.count
                && removedPlugins.contains(removalKey(stage: stageName, plugin: plugins[cursor]))
            let removeLabel = isCurrentRemoved ? "d undelete" : "d remove"

            terminal.drawScreen(
                title: "\(stageName) plugins",
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  a add  \(removeLabel)  r reorder  s save  Esc back"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(max(items.count - 1, 0), cursor + 1)
            case .pageUp: cursor = max(0, cursor - 10)
            case .pageDown: cursor = min(max(items.count - 1, 0), cursor + 10)
            case .char("a"):
                addPlugin(stageName: stageName)
            case .char("d"):
                if !plugins.isEmpty, cursor < plugins.count {
                    let rmKey = removalKey(stage: stageName, plugin: plugins[cursor])
                    if removedPlugins.contains(rmKey) {
                        removedPlugins.remove(rmKey)
                    } else {
                        removedPlugins.insert(rmKey)
                        modified = true
                    }
                }
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

    // MARK: - Add Plugin

    private func addPlugin(stageName: String) {
        let currentPlugins = Set(config.pipeline[stageName] ?? [])
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

        var list = config.pipeline[stageName] ?? []
        list.append(available[idx])
        config.pipeline[stageName] = list
        modified = true
    }

    // MARK: - Interactive Reorder

    private func interactiveReorder(stageName: String, startIndex: Int) -> Int? {
        var position = startIndex
        let originalList = config.pipeline[stageName] ?? []
        let count = originalList.count

        while true {
            let plugins = config.pipeline[stageName] ?? []
            let items: [String] = plugins.enumerated().map { idx, plugin in
                let key = removalKey(stage: stageName, plugin: plugin)
                if idx == position {
                    return "  \(ANSI.italic)\(plugin)\(ANSI.reset)"
                }
                if removedPlugins.contains(key) {
                    return "\(ANSI.dim)" + strikethrough(plugin) + "\(ANSI.reset)"
                }
                return plugin
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
                    var list = config.pipeline[stageName] ?? []
                    list.swapAt(position, position - 1)
                    config.pipeline[stageName] = list
                    position -= 1
                }
            case .cursorDown:
                if position < count - 1 {
                    var list = config.pipeline[stageName] ?? []
                    list.swapAt(position, position + 1)
                    config.pipeline[stageName] = list
                    position += 1
                }
            case .enter:
                if position != startIndex { modified = true }
                return position
            case .escape:
                config.pipeline[stageName] = originalList
                return nil
            default: break
            }
        }
    }

    // MARK: - Save / Quit

    private func save() {
        applyRemovals()
        do {
            try config.save()
            modified = false
            terminal.showMessage("Config saved.")
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }

    private func applyRemovals() {
        for key in removedPlugins {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let stage = String(parts[0])
            let plugin = String(parts[1])
            config.pipeline[stage]?.removeAll { $0 == plugin }
        }
        removedPlugins.removeAll()
    }

    private func quit() {
        terminal.restore()
        Foundation.exit(0)
    }

    private func promptUnsavedAndExit() {
        if !modified { quit() }

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
            case .char("d"):
                quit()
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
