import Foundation
import PiqleyCore

extension ConfigWizard {
    func addStage() {
        guard let name = terminal.promptForInput(title: "New stage name", hint: "lowercase-with-hyphens") else { return }
        guard StageRegistry.isValidName(name) else {
            terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
            return
        }
        guard !registry.isKnown(name) else {
            terminal.showMessage("Stage '\(name)' already exists.")
            return
        }
        let positions = registry.active.enumerated().map { "\($0.offset): before \($0.element.name)" }
            + ["\(registry.active.count): at end"]
        guard let posIdx = terminal.selectFromFilterableList(title: "Insert position", items: positions) else { return }
        do {
            try registry.addStage(name, at: posIdx)
            workflow.pipeline[name] = []
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func duplicateStage(at cursor: Int) {
        let stages = registry.executionOrder
        guard cursor < stages.count else { return }
        let sourceName = stages[cursor]
        guard let newName = terminal.promptForInput(title: "Duplicate '\(sourceName)' as", hint: "lowercase-with-hyphens") else { return }
        guard StageRegistry.isValidName(newName) else {
            terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
            return
        }
        guard !registry.isKnown(newName) else {
            terminal.showMessage("Stage '\(newName)' already exists.")
            return
        }
        // Copy stage files in this workflow's rules dir
        let rulesDir = WorkflowStore.rulesDirectory(name: workflow.name)
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for pluginDir in pluginDirs {
                let sourceFile = pluginDir.appendingPathComponent(
                    "\(PluginFile.stagePrefix)\(sourceName)\(PluginFile.stageSuffix)"
                )
                let destFile = pluginDir.appendingPathComponent(
                    "\(PluginFile.stagePrefix)\(newName)\(PluginFile.stageSuffix)"
                )
                if FileManager.default.fileExists(atPath: sourceFile.path) {
                    try? FileManager.default.copyItem(at: sourceFile, to: destFile)
                }
            }
        }
        do {
            try registry.addStage(newName, at: cursor + 1)
            workflow.pipeline[newName] = workflow.pipeline[sourceName] ?? []
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func activateStage() {
        guard !registry.available.isEmpty else {
            terminal.showMessage("No available stages to activate.")
            return
        }
        let items = registry.available.map(\.name)
        guard let idx = terminal.selectFromFilterableList(title: "Activate stage", items: items) else { return }
        let name = items[idx]
        let positions = registry.active.enumerated().map { "\($0.offset): before \($0.element.name)" }
            + ["\(registry.active.count): at end"]
        guard let posIdx = terminal.selectFromFilterableList(title: "Insert position", items: positions) else { return }
        do {
            try registry.activate(name, at: posIdx)
            if workflow.pipeline[name] == nil {
                workflow.pipeline[name] = []
            }
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func removeStage(_ name: String) {
        guard !StageRegistry.isRequired(name) else {
            terminal.showMessage("'\(name)' is a required stage and cannot be removed.")
            return
        }
        do {
            try registry.deactivate(name)
            workflow.pipeline.removeValue(forKey: name)

            // Delete stage files from all plugin rules dirs in this workflow
            let rulesDir = WorkflowStore.rulesDirectory(name: workflow.name)
            if let pluginDirs = try? FileManager.default.contentsOfDirectory(
                at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for pluginDir in pluginDirs {
                    let stageFile = pluginDir.appendingPathComponent(
                        "\(PluginFile.stagePrefix)\(name)\(PluginFile.stageSuffix)"
                    )
                    if FileManager.default.fileExists(atPath: stageFile.path) {
                        try FileManager.default.removeItem(at: stageFile)
                    }
                }
            }

            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func renameStage(_ oldName: String) {
        guard !StageRegistry.isRequired(oldName) else {
            terminal.showMessage("'\(oldName)' is a required stage and cannot be renamed.")
            return
        }
        guard let newName = terminal.promptForInput(title: "Rename '\(oldName)' to", hint: "lowercase-with-hyphens") else { return }
        guard StageRegistry.isValidName(newName) else {
            terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
            return
        }
        do {
            // Rename stage files in this workflow's rules dir
            let rulesDir = WorkflowStore.rulesDirectory(name: workflow.name)
            if let pluginDirs = try? FileManager.default.contentsOfDirectory(
                at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for pluginDir in pluginDirs {
                    let oldFile = pluginDir.appendingPathComponent(
                        "\(PluginFile.stagePrefix)\(oldName)\(PluginFile.stageSuffix)"
                    )
                    let newFile = pluginDir.appendingPathComponent(
                        "\(PluginFile.stagePrefix)\(newName)\(PluginFile.stageSuffix)"
                    )
                    if FileManager.default.fileExists(atPath: oldFile.path) {
                        try FileManager.default.moveItem(at: oldFile, to: newFile)
                    }
                }
            }

            // Update global registry
            try registry.renameStage(oldName, to: newName)

            // Update this workflow's pipeline
            if let plugins = workflow.pipeline.removeValue(forKey: oldName) {
                workflow.pipeline[newName] = plugins
            }

            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func reorderStage(startIndex: Int) -> Int? {
        var position = startIndex
        let originalActive = registry.active
        let count = originalActive.count

        while true {
            let stages = registry.executionOrder
            let items: [String] = stages.enumerated().map { idx, stage in
                if idx == position {
                    return "  \(ANSI.italic)\(stage)\(ANSI.reset)"
                }
                return stage
            }

            terminal.drawScreen(
                title: "Reorder stages",
                items: items,
                cursor: position,
                footer: "\u{2191}\u{2193} move  \u{23CE} confirm  Esc cancel"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp:
                if position > 0 {
                    registry.active.swapAt(position, position - 1)
                    position -= 1
                }
            case .cursorDown:
                if position < count - 1 {
                    registry.active.swapAt(position, position + 1)
                    position += 1
                }
            case .enter:
                if position != startIndex { modified = true }
                return position
            case .escape:
                registry.active = originalActive
                return nil
            default: break
            }
        }
    }
}
