import Foundation

// MARK: - Raw Terminal Mode

/// Manages raw terminal mode for single-keypress input.
/// Saves and restores original terminal settings on deinit.
final class RawTerminal {
    private var originalTermios: termios
    private var isRestored = false

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
        guard !isRestored else { return }
        isRestored = true
        // Show cursor
        write("\u{1b}[?25h")
        // Disable alternate screen buffer
        write("\u{1b}[?1049l")
        // Restore terminal settings
        var saved = originalTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }

    /// Re-enter raw mode after a `restore()` call (e.g. after a nested wizard).
    func reenter() {
        isRestored = false
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 1 // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1b}[?1049h")
        write("\u{1b}[?25l")
    }

    /// Read a single keypress with optional timeout.
    /// Returns `.timeout` if no key is pressed within `timeoutMs` milliseconds.
    /// Pass `nil` for no timeout (blocks indefinitely).
    func readKey(timeoutMs: Int32? = nil) -> Key {
        if let timeout = timeoutMs {
            guard stdinHasData(timeoutMs: timeout) else { return .timeout }
        }
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
                let truncated = ANSI.truncate(text, maxWidth: size.cols - 4)
                buf += "\(ANSI.inverse) \u{25B8} \(truncated) \(ANSI.reset)"
            } else {
                let truncated = ANSI.truncate(text, maxWidth: size.cols - 3)
                buf += "   \(truncated)"
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

    /// Pure navigation helper that skips a divider index. Extracted for testability.
    static func navigateWithDivider(
        key: Key, cursor: Int, itemCount: Int, dividerIndex: Int?
    ) -> Int {
        let maxIdx = max(itemCount - 1, 0)
        var newCursor: Int
        switch key {
        case .cursorUp: newCursor = max(0, cursor - 1)
        case .cursorDown: newCursor = min(maxIdx, cursor + 1)
        case .pageUp: newCursor = max(0, cursor - 10)
        case .pageDown: newCursor = min(maxIdx, cursor + 10)
        default: return cursor
        }
        if let dividerIndex, newCursor == dividerIndex {
            let direction = (key == .cursorUp || key == .pageUp) ? -1 : 1
            newCursor = max(0, min(maxIdx, newCursor + direction))
        }
        return newCursor
    }

    /// Show a selectable list with a non-selectable divider row.
    /// Returns the chosen index, or nil if cancelled.
    /// Items before the divider are selected with Enter; items after require 'a' to activate.
    func selectFromListWithDivider(
        title: String, items: [String], dividerIndex: Int?
    ) -> Int? {
        var cursor = 0
        while true {
            let isOnInactive = dividerIndex.map { cursor > $0 } ?? false
            let footer = isOnInactive
                ? "\u{2191}\u{2193} navigate  a activate  Esc cancel"
                : "\u{2191}\u{2193} navigate  \u{23CE} select  Esc cancel"

            drawScreen(
                title: title,
                items: items,
                cursor: cursor,
                footer: footer
            )

            let key = readKey()
            switch key {
            case .cursorUp, .cursorDown, .pageUp, .pageDown:
                cursor = Self.navigateWithDivider(
                    key: key, cursor: cursor, itemCount: items.count, dividerIndex: dividerIndex
                )
            case .enter where !isOnInactive && cursor != dividerIndex:
                return cursor
            case .char("a") where isOnInactive:
                return cursor
            case .escape, .ctrlC: return nil
            default: break
            }
        }
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

    /// Prompt for text input. Returns nil if cancelled.
    func promptForInput(title: String, hint: String, defaultValue: String? = nil, allowEmpty: Bool = false) -> String? {
        var input = defaultValue ?? ""
        var cursorPos = input.count
        let size = ANSI.terminalSize()

        while true {
            let before = String(input.prefix(cursorPos))
            let after = String(input.suffix(input.count - cursorPos))
            var buf = ""
            buf += ANSI.clearScreen()
            buf += ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(title)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 2, col: 1)
            buf += "\(ANSI.dim)\(hint)\(ANSI.reset)"
            buf += ANSI.moveTo(row: 4, col: 1)
            buf += "\u{25B8} \(before)\u{2588}\(after)"
            buf += ANSI.moveTo(row: size.rows, col: 1)
            buf += "\(ANSI.dim)\u{2190}\u{2192} move cursor  Enter to confirm  Esc to cancel\(ANSI.reset)"
            write(buf)

            let key = readKey()
            switch key {
            case let .char(char):
                input.insert(char, at: input.index(input.startIndex, offsetBy: cursorPos))
                cursorPos += 1
            case .backspace:
                if cursorPos > 0 {
                    input.remove(at: input.index(input.startIndex, offsetBy: cursorPos - 1))
                    cursorPos -= 1
                }
            case .cursorLeft:
                if cursorPos > 0 { cursorPos -= 1 }
            case .cursorRight:
                if cursorPos < input.count { cursorPos += 1 }
            case .enter:
                if !input.isEmpty || allowEmpty { return input }
            case .escape, .ctrlC:
                return nil
            default: break
            }
        }
    }

    private func renderSuggestions(
        matches: [String], scrollOffset: Int, maxSuggestions: Int,
        highlightIndex: Int, startRow: Int
    ) -> String {
        let visibleEnd = min(scrollOffset + maxSuggestions, matches.count)
        var buf = ""
        for globalIdx in scrollOffset ..< visibleEnd {
            buf += ANSI.moveTo(row: startRow + globalIdx - scrollOffset, col: 3)
            if globalIdx == highlightIndex {
                buf += "\(ANSI.dim)Tab \u{2192} \(ANSI.reset)\(matches[globalIdx])"
            } else {
                buf += "\(ANSI.dim)  \(matches[globalIdx])\(ANSI.reset)"
            }
        }
        let remaining = matches.count - visibleEnd
        if remaining > 0 {
            buf += ANSI.moveTo(row: startRow + visibleEnd - scrollOffset, col: 3)
            buf += "\(ANSI.dim)  ... \(remaining) more\(ANSI.reset)"
        }
        return buf
    }

    /// Prompt for text input with autocomplete suggestions.
    /// Tab completes the top match. If `browsableList` is provided, Ctrl+L opens
    /// a selectable list to pick from. Returns nil if cancelled.
    ///
    /// - Parameter insertCompletions: When provided, Tab inserts the value at the
    ///   same index from this array instead of the display completion. Must be the
    ///   same length as `completions`.
    func promptWithAutocomplete(
        title: String, hint: String, completions: [String],
        browsableList: [String]? = nil, defaultValue: String? = nil,
        allowEmpty: Bool = false, insertCompletions: [String]? = nil,
        noMatchHint: String? = nil, subtitleNote: String? = nil,
        triggerPrefix: String? = nil
    ) -> String? {
        var input = defaultValue ?? ""
        var cursorPos = input.count
        let size = ANSI.terminalSize()
        let maxSuggestions = 5
        let hasList = browsableList != nil
        var tabCycleIndex = 0
        var lastTabQuery = ""
        var arrowIndex: Int?
        var scrollOffset = 0

        while true {
            let (query, templateInsertRange) = resolveAutocompleteQuery(
                input: input, cursorPos: cursorPos, triggerPrefix: triggerPrefix
            )
            let matchedIndices: [Int] = query.isEmpty && triggerPrefix != nil
                ? []
                : query.isEmpty
                ? Array(completions.indices)
                : completions.enumerated().compactMap { idx, item in
                    item.lowercased().contains(query) ? idx : nil
                }
            let matches = matchedIndices.map { completions[$0] }

            let before = String(input.prefix(cursorPos))
            let after = String(input.suffix(input.count - cursorPos))
            let titleLines = title.components(separatedBy: "\n").count
            let hintLines = hint.components(separatedBy: "\n").count
            let inputRow = titleLines + hintLines + 2
            let suggestionsRow = inputRow + 2
            let visibleEnd = min(scrollOffset + maxSuggestions, matches.count)
            let highlightIndex = arrowIndex ?? (
                matchedIndices.isEmpty ? scrollOffset : {
                    let pos = tabCycleIndex % matchedIndices.count
                    return (pos >= scrollOffset && pos < visibleEnd) ? pos : scrollOffset
                }()
            )

            var buf = ANSI.clearScreen() + ANSI.moveTo(row: 1, col: 1)
            buf += "\(ANSI.bold)\(title)\(ANSI.reset)"
            buf += ANSI.moveTo(row: titleLines + 1, col: 1)
            buf += "\(ANSI.dim)\(hint)\(ANSI.reset)"
            buf += ANSI.moveTo(row: inputRow, col: 1)
            buf += "\u{25B8} \(before)\u{2588}\(after)"
            var nextRow = suggestionsRow
            if !matches.isEmpty {
                buf += renderSuggestions(
                    matches: matches, scrollOffset: scrollOffset,
                    maxSuggestions: maxSuggestions, highlightIndex: highlightIndex,
                    startRow: suggestionsRow
                )
                let visibleCount = min(maxSuggestions, matches.count - scrollOffset)
                let hasMoreLine = matches.count > scrollOffset + maxSuggestions ? 1 : 0
                nextRow = suggestionsRow + visibleCount + hasMoreLine
            } else if !input.isEmpty, let noMatchHint {
                buf += ANSI.moveTo(row: suggestionsRow, col: 3)
                buf += "\(ANSI.dim)\(noMatchHint)\(ANSI.reset)"
                nextRow = suggestionsRow + 1
            }
            if let subtitleNote {
                buf += ANSI.moveTo(row: nextRow + 1, col: 3)
                buf += "\(ANSI.dim)\(subtitleNote)\(ANSI.reset)"
            }
            let listHint = hasList ? "  Ctrl+L browse list" : ""
            buf += ANSI.moveTo(row: size.rows, col: 1)
            buf += "\(ANSI.dim)\u{2190}\u{2192} move  Tab autocomplete\(listHint)  Enter confirm  Esc cancel\(ANSI.reset)"
            write(buf)

            switch readKey() {
            case .ctrlL where hasList:
                if let list = browsableList, let idx = selectFromList(title: "Select field", items: list) {
                    input = list[idx]
                    cursorPos = input.count
                }
            case let .char(char):
                input.insert(char, at: input.index(input.startIndex, offsetBy: cursorPos))
                cursorPos += 1
                arrowIndex = nil
                scrollOffset = 0
            case .backspace:
                guard cursorPos > 0 else { continue }
                input.remove(at: input.index(input.startIndex, offsetBy: cursorPos - 1))
                cursorPos -= 1
                arrowIndex = nil
                scrollOffset = 0
            case .cursorLeft:
                if cursorPos > 0 { cursorPos -= 1 }
            case .cursorRight:
                if cursorPos < input.count { cursorPos += 1 }
            case .cursorDown where !matchedIndices.isEmpty:
                arrowIndex = min((arrowIndex ?? -1) + 1, matchedIndices.count - 1)
                if arrowIndex! >= scrollOffset + maxSuggestions {
                    scrollOffset = arrowIndex! - maxSuggestions + 1
                }
            case .cursorUp where arrowIndex != nil && arrowIndex! > 0:
                arrowIndex = arrowIndex! - 1
                if arrowIndex! < scrollOffset { scrollOffset = arrowIndex! }
            case .tab:
                guard !matchedIndices.isEmpty else { continue }
                let selectedIdx: Int
                if let arrow = arrowIndex {
                    selectedIdx = matchedIndices[arrow]
                    tabCycleIndex = arrow + 1
                    lastTabQuery = query
                    arrowIndex = nil
                    scrollOffset = 0
                } else {
                    if query != lastTabQuery { tabCycleIndex = 0; lastTabQuery = query }
                    selectedIdx = matchedIndices[tabCycleIndex % matchedIndices.count]
                    tabCycleIndex += 1
                }
                let completionValue = insertCompletions?[selectedIdx] ?? completions[selectedIdx]
                applyTabCompletion(
                    completionValue: completionValue,
                    triggerPrefix: triggerPrefix,
                    templateInsertRange: templateInsertRange,
                    input: &input,
                    cursorPos: &cursorPos
                )
            case .enter:
                if !input.isEmpty || allowEmpty { return input }
            case .escape, .ctrlC:
                return nil
            default: break
            }
        }
    }
}
