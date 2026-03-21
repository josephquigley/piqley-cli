import Foundation
import PiqleyCore

// MARK: - All Plugins browser, detail view, and actions

extension ConfigWizard {
    /// An entry in the "All Plugins" list — either a discovered plugin or a
    /// missing identifier referenced only in the pipeline config.
    enum PluginEntry {
        case discovered(LoadedPlugin)
        case missing(String)

        var identifier: String {
            switch self {
            case let .discovered(plugin): plugin.identifier
            case let .missing(identifier): identifier
            }
        }
    }

    func allPluginEntries() -> [PluginEntry] {
        let pipelineIdentifiers = Set(workflow.pipeline.values.flatMap(\.self))
        let missingIdentifiers = pipelineIdentifiers.subtracting(discoveredIdentifiers)

        var entries: [PluginEntry] = discoveredPlugins.map { .discovered($0) }
        for missingID in missingIdentifiers.sorted() {
            entries.append(.missing(missingID))
        }
        return entries.sorted { $0.identifier < $1.identifier }
    }

    func pluginDisplayName(for entry: PluginEntry) -> String {
        switch entry {
        case let .discovered(plugin): plugin.name
        case let .missing(identifier): identifier
        }
    }

    // MARK: - Filterable Plugin Browser

    func showAllPlugins() {
        var filter = ""
        var cursor = 0

        while true {
            let entries = allPluginEntries()
            let query = filter.lowercased()
            let filtered: [(index: Int, entry: PluginEntry)] = query.isEmpty
                ? entries.enumerated().map { ($0.offset, $0.element) }
                : entries.enumerated().compactMap { idx, entry in
                    let name = pluginDisplayName(for: entry).lowercased()
                    let ident = entry.identifier.lowercased()
                    return (name.contains(query) || ident.contains(query)) ? (idx, entry) : nil
                }

            cursor = min(cursor, max(0, filtered.count - 1))

            drawAllPluginsScreen(
                filtered: filtered, cursor: cursor,
                filter: filter, totalCount: entries.count
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(max(filtered.count - 1, 0), cursor + 1)
            case .pageUp: cursor = max(0, cursor - 5)
            case .pageDown: cursor = min(max(filtered.count - 1, 0), cursor + 5)
            case .enter:
                if !filtered.isEmpty, cursor < filtered.count {
                    pluginDetail(entry: filtered[cursor].entry)
                }
            case .escape, .ctrlC:
                if !filter.isEmpty {
                    filter = ""
                    cursor = 0
                } else {
                    return
                }
            case .backspace:
                if !filter.isEmpty { filter.removeLast() }
            case let .char(char):
                filter.append(char)
                cursor = 0
            default: break
            }
        }
    }

    private func drawAllPluginsScreen(
        filtered: [(index: Int, entry: PluginEntry)],
        cursor: Int, filter: String, totalCount: Int
    ) {
        let size = ANSI.terminalSize()
        let activeSet = Set(workflow.pipeline.values.flatMap(\.self))

        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)All Plugins\(ANSI.reset)"

        // Filter line
        buf += ANSI.moveTo(row: 2, col: 1)
        if filter.isEmpty {
            buf += "\(ANSI.dim)Type to filter\(ANSI.reset)"
        } else {
            buf += "Filter: \(filter)\u{2588}  "
            buf += "\(ANSI.dim)(\(filtered.count) of \(totalCount))\(ANSI.reset)"
        }

        if filtered.isEmpty {
            buf += ANSI.moveTo(row: 4, col: 4)
            buf += "\(ANSI.dim)(no matches)\(ANSI.reset)"
        } else {
            // Each entry takes 2 rows: name line + identifier line
            let itemStartRow = 4
            let maxVisible = (size.rows - itemStartRow - 1) / 2
            let scrollOffset = max(0, cursor - maxVisible + 1)
            let visible = Array(filtered.enumerated())
                .dropFirst(scrollOffset).prefix(maxVisible)

            for (row, item) in visible.enumerated() {
                let (_, entry) = item.element
                let nameRow = itemStartRow + row * 2
                let isCursor = item.offset == cursor

                switch entry {
                case let .discovered(plugin):
                    buf += drawDiscoveredEntry(
                        plugin: plugin, activeSet: activeSet,
                        nameRow: nameRow, isCursor: isCursor
                    )
                case let .missing(identifier):
                    buf += drawMissingEntry(
                        identifier: identifier,
                        nameRow: nameRow, isCursor: isCursor
                    )
                }
            }

            if filtered.count > maxVisible {
                let rangeEnd = min(scrollOffset + maxVisible, filtered.count)
                buf += ANSI.moveTo(row: 3, col: size.cols - 12)
                buf += "\(ANSI.dim)\(scrollOffset + 1)-\(rangeEnd)"
                buf += " of \(filtered.count)\(ANSI.reset)"
            }
        }

        buf += ANSI.moveTo(row: size.rows, col: 1)
        let escLabel = filter.isEmpty ? "back" : "clear filter"
        buf += "\(ANSI.dim)\u{2191}\u{2193} navigate  "
        buf += "\u{23CE} details  Esc \(escLabel)\(ANSI.reset)"

        terminal.write(buf)
    }

    private func drawDiscoveredEntry(
        plugin: LoadedPlugin, activeSet: Set<String>,
        nameRow: Int, isCursor: Bool
    ) -> String {
        let pipelineStages = workflow.pipeline.compactMap { stage, list in
            list.contains(plugin.identifier) ? stage : nil
        }.sorted()
        let stageInfo = pipelineStages.isEmpty
            ? "\(ANSI.dim)not in pipeline\(ANSI.reset)"
            : pipelineStages.joined(separator: ", ")
        let status = activeSet.contains(plugin.identifier)
            ? "\(ANSI.green)active\(ANSI.reset)"
            : "\(ANSI.dim)inactive\(ANSI.reset)"
        let version = plugin.manifest.pluginVersion.map { "v\($0)" } ?? ""

        var buf = ANSI.moveTo(row: nameRow, col: 1)
        if isCursor {
            buf += "\(ANSI.inverse) \u{25B8} \(plugin.name) \(ANSI.reset)"
            buf += "  \(status)  \(stageInfo)"
        } else {
            buf += "   \(plugin.name)  \(status)  \(stageInfo)"
        }
        buf += ANSI.moveTo(row: nameRow + 1, col: 4)
        buf += "\(ANSI.dim)\(ANSI.italic)\(plugin.identifier)"
        buf += "  \(version)\(ANSI.reset)"
        return buf
    }

    private func drawMissingEntry(
        identifier: String, nameRow: Int, isCursor: Bool
    ) -> String {
        let pipelineStages = workflow.pipeline.compactMap { stage, list in
            list.contains(identifier) ? stage : nil
        }.sorted()

        var buf = ANSI.moveTo(row: nameRow, col: 1)
        if isCursor {
            buf += "\(ANSI.inverse) \u{25B8} \(identifier) \(ANSI.reset)"
            buf += "  \(ANSI.red)missing\(ANSI.reset)"
            buf += "  \(pipelineStages.joined(separator: ", "))"
        } else {
            buf += "   \(identifier)"
            buf += "  \(ANSI.red)missing\(ANSI.reset)"
            buf += "  \(pipelineStages.joined(separator: ", "))"
        }
        buf += ANSI.moveTo(row: nameRow + 1, col: 4)
        buf += "\(ANSI.dim)\(ANSI.italic)not found on disk\(ANSI.reset)"
        return buf
    }

    // MARK: - Plugin Detail

    private func pluginDetail(entry: PluginEntry) {
        switch entry {
        case let .discovered(plugin):
            showDiscoveredPluginDetail(plugin: plugin)
        case .missing:
            pluginActions(entry: entry)
        }
    }

    func showDiscoveredPluginDetail(plugin: LoadedPlugin) {
        let manifest = plugin.manifest
        let allStages = Hook.canonicalOrder.map(\.rawValue)

        while true {
            let pipelineStages = allStages.filter { stage in
                (workflow.pipeline[stage] ?? []).contains(plugin.identifier)
            }

            let size = ANSI.terminalSize()
            var buf = ""
            buf += ANSI.clearScreen()
            buf += ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(manifest.name)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 2, col: 1)
            buf += "\(ANSI.dim)\(ANSI.italic)\(manifest.identifier)\(ANSI.reset)"

            var row = 4
            if let desc = manifest.description, !desc.isEmpty {
                buf += ANSI.moveTo(row: row, col: 1)
                buf += desc
                row += 2
            }

            buf += drawManifestFields(
                manifest: manifest, plugin: plugin,
                pipelineStages: pipelineStages, startRow: row
            )
            row = manifestFieldsEndRow(
                manifest: manifest, pipelineStages: pipelineStages,
                startRow: row
            )

            // Action options
            row += 1
            var menuItems: [(label: String, action: PluginAction)] = []
            let pluginStages = Set(plugin.stages.keys)
            let addableStages = allStages.filter {
                !pipelineStages.contains($0) && pluginStages.contains($0)
            }
            for stage in addableStages {
                menuItems.append((
                    label: "Add to \(stage)", action: .addToStage(stage)
                ))
            }
            for stage in pipelineStages {
                menuItems.append((
                    label: "Remove from \(stage)", action: .removeFromStage(stage)
                ))
            }

            for (idx, item) in menuItems.enumerated() {
                buf += ANSI.moveTo(row: row + idx, col: 3)
                buf += "\(ANSI.dim)\(idx + 1).\(ANSI.reset) \(item.label)"
            }

            buf += ANSI.moveTo(row: size.rows, col: 1)
            buf += "\(ANSI.dim)1-\(menuItems.count) select action"
            buf += "  Esc back\(ANSI.reset)"

            terminal.write(buf)

            let key = terminal.readKey()
            switch key {
            case .escape:
                return
            case let .char(char):
                if let digit = char.wholeNumberValue,
                   digit >= 1, digit <= menuItems.count
                {
                    applyAction(
                        menuItems[digit - 1].action,
                        identifier: plugin.identifier
                    )
                    return
                }
            default: break
            }
        }
    }

    private func drawManifestFields(
        manifest: PluginManifest, plugin: LoadedPlugin,
        pipelineStages: [String], startRow: Int
    ) -> String {
        var buf = ""
        var row = startRow

        let version = manifest.pluginVersion.map { "\($0)" } ?? "\u{2014}"
        buf += ANSI.moveTo(row: row, col: 1)
        buf += "\(ANSI.dim)Version:\(ANSI.reset)  \(version)"
        row += 1

        buf += ANSI.moveTo(row: row, col: 1)
        buf += "\(ANSI.dim)Schema:\(ANSI.reset)   \(manifest.pluginSchemaVersion)"
        row += 1

        let stageNames = Hook.canonicalOrder.map(\.rawValue).filter { plugin.stages.keys.contains($0) }
        buf += ANSI.moveTo(row: row, col: 1)
        let stagesStr = stageNames.isEmpty ? "none" : stageNames.joined(separator: ", ")
        buf += "\(ANSI.dim)Stages:\(ANSI.reset)   \(stagesStr)"
        row += 1

        buf += ANSI.moveTo(row: row, col: 1)
        let pipeStr = pipelineStages.isEmpty
            ? "not in pipeline" : pipelineStages.joined(separator: ", ")
        buf += "\(ANSI.dim)Pipeline:\(ANSI.reset) \(pipeStr)"
        row += 1

        let deps = manifest.dependencyIdentifiers
        if !deps.isEmpty {
            buf += ANSI.moveTo(row: row, col: 1)
            buf += "\(ANSI.dim)Depends:\(ANSI.reset)  \(deps.joined(separator: ", "))"
        }

        let secrets = manifest.secretKeys
        if !secrets.isEmpty {
            row += deps.isEmpty ? 0 : 1
            buf += ANSI.moveTo(row: row, col: 1)
            buf += "\(ANSI.dim)Secrets:\(ANSI.reset)  \(secrets.joined(separator: ", "))"
        }

        let configValues = manifest.valueEntries
        if !configValues.isEmpty {
            row += (deps.isEmpty && secrets.isEmpty) ? 0 : 1
            buf += ANSI.moveTo(row: row, col: 1)
            buf += "\(ANSI.dim)Config:\(ANSI.reset)   "
            buf += configValues.map(\.key).joined(separator: ", ")
        }

        return buf
    }

    private func manifestFieldsEndRow(
        manifest: PluginManifest, pipelineStages _: [String], startRow: Int
    ) -> Int {
        var row = startRow + 4 // version, schema, stages, pipeline
        if !manifest.dependencyIdentifiers.isEmpty { row += 1 }
        if !manifest.secretKeys.isEmpty { row += 1 }
        if !manifest.valueEntries.isEmpty { row += 1 }
        return row
    }

    // MARK: - Plugin Actions (missing plugins)

    func pluginActions(entry: PluginEntry) {
        let allStages = Hook.canonicalOrder.map(\.rawValue)
        let identifier = entry.identifier
        let isMissing = if case .missing = entry { true } else { false }

        while true {
            let stagesContaining = allStages.filter { stage in
                (workflow.pipeline[stage] ?? []).contains(identifier)
            }

            var menuItems: [(label: String, action: PluginAction)] = []

            if case let .discovered(plugin) = entry {
                let pluginStages = Set(plugin.stages.keys)
                let addableStages = allStages.filter { stage in
                    !(workflow.pipeline[stage] ?? []).contains(identifier)
                        && pluginStages.contains(stage)
                }
                for stage in addableStages {
                    menuItems.append((
                        label: "Add to \(stage)",
                        action: .addToStage(stage)
                    ))
                }
            }

            for stage in stagesContaining {
                menuItems.append((
                    label: "Remove from \(stage)",
                    action: .removeFromStage(stage)
                ))
            }

            if menuItems.isEmpty {
                terminal.showMessage("No actions available for \(identifier).")
                return
            }

            var titleDesc: String
            switch entry {
            case let .discovered(plugin):
                let version = plugin.manifest.pluginVersion.map { "\($0)" } ?? "\u{2014}"
                titleDesc = "\(ANSI.dim)v\(version)\(ANSI.reset)"
                if let about = plugin.manifest.description, !about.isEmpty {
                    titleDesc += "  \(ANSI.dim)\(about)\(ANSI.reset)"
                }
            case .missing:
                titleDesc = "\(ANSI.red)not found on disk\(ANSI.reset)"
            }

            guard let choice = terminal.selectFromList(
                title: "\(identifier)\n\(titleDesc)",
                items: menuItems.map(\.label)
            ) else {
                return
            }

            applyAction(menuItems[choice].action, identifier: identifier)
        }
    }

    enum PluginAction {
        case addToStage(String)
        case removeFromStage(String)
    }

    func applyAction(_ action: PluginAction, identifier: String) {
        switch action {
        case let .addToStage(stage):
            var list = workflow.pipeline[stage] ?? []
            list.append(identifier)
            workflow.pipeline[stage] = list
            modified = true
        case let .removeFromStage(stage):
            workflow.pipeline[stage]?.removeAll { $0 == identifier }
            modified = true
        }
    }
}
