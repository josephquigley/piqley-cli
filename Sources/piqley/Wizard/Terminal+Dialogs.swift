import Foundation

// MARK: - Dialog helpers (confirm, showMessage, selectFromFilterableList)

extension RawTerminal {
    /// Show a y/n confirmation. Returns true for yes.
    func confirm(_ message: String) -> Bool {
        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)\(message)\(ANSI.reset)"
        buf += ANSI.moveTo(row: 3, col: 1)
        buf += "y/n \u{25B8} "
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)y yes  n no\(ANSI.reset)"
        write(buf)

        while true {
            let key = readKey()
            switch key {
            case .char("y"), .char("Y"): return true
            case .char("n"), .char("N"), .escape: return false
            default: break
            }
        }
    }

    /// Show a brief message, wait for keypress.
    func showMessage(_ message: String) {
        let size = ANSI.terminalSize()
        var buf = ""
        buf += ANSI.clearScreen()
        buf += ANSI.moveTo(row: 1, col: 1)
        buf += "\(ANSI.bold)\(message)\(ANSI.reset)"
        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)Press any key to continue\(ANSI.reset)"
        write(buf)
        _ = readKey()
    }

    /// Show a selectable list with live filtering. Returns the index into the
    /// original `items` array, or nil if cancelled.
    func selectFromFilterableList(title: String, items: [String]) -> Int? {
        var filter = ""
        var cursor = 0

        while true {
            let query = filter.lowercased()
            // Build filtered list with original indices
            let filtered: [(index: Int, text: String)] = query.isEmpty
                ? items.enumerated().map { ($0.offset, $0.element) }
                : items.enumerated().compactMap { idx, text in
                    text.lowercased().contains(query) ? (idx, text) : nil
                }

            let displayItems = filtered.isEmpty ? ["(no matches)"] : filtered.map(\.text)
            cursor = min(cursor, max(0, displayItems.count - 1))

            let filterLine = filter.isEmpty
                ? "\(ANSI.dim)Type to filter\(ANSI.reset)"
                : "Filter: \(filter)\u{2588}  \(ANSI.dim)(\(filtered.count) of \(items.count))\(ANSI.reset)"

            drawScreen(
                title: "\(title)\n\(filterLine)",
                items: displayItems,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} select  Esc \(filter.isEmpty ? "cancel" : "clear filter")"
            )

            let key = readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(displayItems.count - 1, cursor + 1)
            case .pageUp: cursor = max(0, cursor - 10)
            case .pageDown: cursor = min(displayItems.count - 1, cursor + 10)
            case .enter:
                if !filtered.isEmpty, cursor < filtered.count {
                    return filtered[cursor].index
                }
            case .escape, .ctrlC:
                if !filter.isEmpty {
                    filter = ""
                    cursor = 0
                } else {
                    return nil
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
}
