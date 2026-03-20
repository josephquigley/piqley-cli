import Foundation

// MARK: - Raw Terminal Mode

/// Manages raw terminal mode for single-keypress input.
/// Saves and restores original terminal settings on deinit.
final class RawTerminal {
    private var originalTermios: termios

    init() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw

        // Enter raw mode: no echo, no canonical processing, no signals
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        // Read returns after 1 byte, with 100ms timeout for escape sequences
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 1 // VTIME (tenths of a second)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Enable alternate screen buffer
        write("\u{1b}[?1049h")
        // Hide cursor
        write("\u{1b}[?25l")
    }

    deinit {
        restore()
    }

    func restore() {
        // Show cursor
        write("\u{1b}[?25h")
        // Disable alternate screen buffer
        write("\u{1b}[?1049l")
        // Restore terminal settings
        var saved = originalTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }

    /// Read a single keypress, handling escape sequences for special keys.
    func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 1)
        let bytesRead = read(STDIN_FILENO, &buf, 1)
        guard bytesRead == 1 else { return .unknown }

        let byte = buf[0]

        // Escape sequence
        if byte == 0x1B {
            return readEscapeSequence()
        }

        // Control characters
        if byte == 13 || byte == 10 { return .enter }
        if byte == 127 { return .backspace }
        if byte == 9 { return .tab }
        if byte == 12 { return .ctrlL }
        if byte == 3 { return .ctrlC }

        // Regular printable character
        if byte >= 32 {
            return .char(Character(UnicodeScalar(byte)))
        }

        return .unknown
    }

    /// Check if stdin has data available within the given timeout (milliseconds).
    private func stdinHasData(timeoutMs: Int32) -> Bool {
        var pollFd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&pollFd, 1, timeoutMs) > 0
    }

    private func readEscapeSequence() -> Key {
        // After receiving ESC, check if more bytes follow within 50ms.
        // If not, it's a bare Escape keypress.
        guard stdinHasData(timeoutMs: 50) else { return .escape }

        var first = [UInt8](repeating: 0, count: 1)
        guard read(STDIN_FILENO, &first, 1) == 1 else { return .escape }

        if first[0] == 91 { // '['
            guard stdinHasData(timeoutMs: 50) else { return .escape }
            var second = [UInt8](repeating: 0, count: 1)
            guard read(STDIN_FILENO, &second, 1) == 1 else { return .escape }

            switch second[0] {
            case 65: return .cursorUp
            case 66: return .cursorDown
            case 67: return .cursorRight
            case 68: return .cursorLeft
            case 53: // Page up: ESC[5~
                var tilde = [UInt8](repeating: 0, count: 1)
                _ = read(STDIN_FILENO, &tilde, 1)
                return .pageUp
            case 54: // Page down: ESC[6~
                var tilde = [UInt8](repeating: 0, count: 1)
                _ = read(STDIN_FILENO, &tilde, 1)
                return .pageDown
            default: break
            }
        } else {
            // Alt + key
            return .char(Character(UnicodeScalar(first[0])))
        }
        return .unknown
    }

    /// Write a string to stdout.
    func write(_ str: String) {
        FileHandle.standardOutput.write(Data(str.utf8))
    }
}

// MARK: - Shared TUI Components

extension RawTerminal {
    // MARK: - Drawing

    func drawScreen(title: String, items: [String], cursor: Int, footer: String) {
        let size = ANSI.terminalSize()
        let titleLines = title.split(separator: "\n", omittingEmptySubsequences: false)
        let titleHeight = titleLines.count
        let itemStartRow = titleHeight + 2
        let maxVisible = size.rows - titleHeight - 3
        let scrollOffset = max(0, cursor - maxVisible + 1)

        var buf = ""
        buf += ANSI.clearScreen()
        for (idx, line) in titleLines.enumerated() {
            buf += ANSI.moveTo(row: idx + 1, col: 1)
            if idx == titleLines.count - 1 {
                buf += "\(ANSI.bold)\(line)\(ANSI.reset)"
            } else {
                buf += "\(line)"
            }
        }

        let visible = Array(items.enumerated()).dropFirst(scrollOffset).prefix(maxVisible)
        for (row, entry) in visible.enumerated() {
            let (idx, text) = entry
            buf += ANSI.moveTo(row: row + itemStartRow, col: 1)
            if idx == cursor {
                buf += "\(ANSI.inverse) \u{25B8} \(text) \(ANSI.reset)"
            } else {
                buf += "   \(text)"
            }
        }

        if items.count > maxVisible {
            buf += ANSI.moveTo(row: itemStartRow - 1, col: size.cols - 10)
            buf += "\(ANSI.dim)\(scrollOffset + 1)-\(min(scrollOffset + maxVisible, items.count)) of \(items.count)\(ANSI.reset)"
        }

        buf += ANSI.moveTo(row: size.rows, col: 1)
        buf += "\(ANSI.dim)\(footer)\(ANSI.reset)"

        write(buf)
    }

    /// Show a selectable list and return the chosen index, or nil if cancelled.
    func selectFromList(title: String, items: [String]) -> Int? {
        var cursor = 0
        while true {
            drawScreen(
                title: title,
                items: items,
                cursor: cursor,
                footer: "\u{2191}\u{2193} navigate  \u{23CE} select  Esc cancel"
            )

            let key = readKey()
            switch key {
            case .cursorUp: cursor = max(0, cursor - 1)
            case .cursorDown: cursor = min(items.count - 1, cursor + 1)
            case .pageUp: cursor = max(0, cursor - 10)
            case .pageDown: cursor = min(items.count - 1, cursor + 10)
            case .enter: return cursor
            case .escape, .ctrlC: return nil
            default: break
            }
        }
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

    /// Prompt for text input. Returns nil if cancelled.
    func promptForInput(title: String, hint: String, defaultValue: String? = nil) -> String? {
        var input = defaultValue ?? ""
        let size = ANSI.terminalSize()

        while true {
            var buf = ""
            buf += ANSI.clearScreen()
            buf += ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(title)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 2, col: 1)
            buf += "\(ANSI.dim)\(hint)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 4, col: 1)
            buf += "\u{25B8} \(input)\u{2588}"
            buf += ANSI.moveTo(row: size.rows, col: 1)
            buf += "\(ANSI.dim)Enter to confirm  Esc to cancel\(ANSI.reset)"
            write(buf)

            let key = readKey()
            switch key {
            case let .char(char):
                input.append(char)
            case .backspace:
                if !input.isEmpty { input.removeLast() }
            case .enter:
                if !input.isEmpty { return input }
            case .escape, .ctrlC:
                return nil
            default: break
            }
        }
    }

    /// Prompt for text input with autocomplete suggestions.
    /// Tab completes the top match. If `browsableList` is provided, Ctrl+L opens
    /// a selectable list to pick from. Returns nil if cancelled.
    func promptWithAutocomplete(
        title: String, hint: String, completions: [String],
        browsableList: [String]? = nil, defaultValue: String? = nil
    ) -> String? {
        var input = defaultValue ?? ""
        let size = ANSI.terminalSize()
        let maxSuggestions = 5
        let hasList = browsableList != nil

        while true {
            let query = input.lowercased()
            let matches = query.isEmpty ? [] : completions.filter {
                $0.lowercased().contains(query)
            }

            var buf = ""
            buf += ANSI.clearScreen()
            buf += ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(title)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 2, col: 1)
            buf += "\(ANSI.dim)\(hint)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 4, col: 1)
            buf += "\u{25B8} \(input)\u{2588}"

            // Show suggestions
            for (idx, match) in matches.prefix(maxSuggestions).enumerated() {
                buf += ANSI.moveTo(row: 6 + idx, col: 3)
                if idx == 0 {
                    buf += "\(ANSI.dim)Tab \u{2192} \(ANSI.reset)\(match)"
                } else {
                    buf += "\(ANSI.dim)  \(match)\(ANSI.reset)"
                }
            }
            if matches.count > maxSuggestions {
                buf += ANSI.moveTo(row: 6 + maxSuggestions, col: 3)
                buf += "\(ANSI.dim)  ... \(matches.count - maxSuggestions) more\(ANSI.reset)"
            }

            buf += ANSI.moveTo(row: size.rows, col: 1)
            let listHint = hasList ? "  Ctrl+L browse list" : ""
            buf += "\(ANSI.dim)Tab autocomplete\(listHint)  Enter confirm  Esc cancel\(ANSI.reset)"
            write(buf)

            let key = readKey()
            switch key {
            case .ctrlL where hasList:
                if let list = browsableList,
                   let idx = selectFromList(title: "Select field", items: list)
                {
                    input = list[idx]
                }
            case let .char(char):
                input.append(char)
            case .backspace:
                if !input.isEmpty { input.removeLast() }
            case .tab:
                if let first = matches.first {
                    input = first
                }
            case .enter:
                if !input.isEmpty { return input }
            case .escape, .ctrlC:
                return nil
            default: break
            }
        }
    }

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
}

// MARK: - Key Enum

enum Key: Equatable {
    case char(Character)
    case enter
    case escape
    case backspace
    case tab
    case cursorUp
    case cursorDown
    case cursorLeft
    case cursorRight
    case pageUp
    case pageDown
    case ctrlC
    case ctrlL
    case unknown
}

// MARK: - ANSI Helpers

enum ANSI {
    static func moveTo(row: Int, col: Int) -> String { "\u{1b}[\(row);\(col)H" }
    static func clearScreen() -> String { "\u{1b}[2J\u{1b}[H" }
    static func clearLine() -> String { "\u{1b}[2K" }
    static let bold = "\u{1b}[1m"
    static let dim = "\u{1b}[2m"
    static let italic = "\u{1b}[3m"
    static let reset = "\u{1b}[0m"
    static let inverse = "\u{1b}[7m"
    static let white = "\u{1b}[37m"
    static let cyan = "\u{1b}[36m"
    static let green = "\u{1b}[32m"
    static let red = "\u{1b}[31m"
    static let yellow = "\u{1b}[33m"

    /// Get terminal size (rows, cols).
    static func terminalSize() -> (rows: Int, cols: Int) {
        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 {
            return (Int(windowSize.ws_row), Int(windowSize.ws_col))
        }
        return (24, 80) // fallback
    }
}
