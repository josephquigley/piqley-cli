import Foundation

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

    /// Truncate a string to `maxWidth` visible characters, preserving ANSI escapes.
    /// Appends "…" when truncated and resets formatting.
    static func truncate(_ string: String, maxWidth: Int) -> String {
        guard maxWidth > 0 else { return "" }
        var visible = 0
        var result = ""
        var idx = string.startIndex
        while idx < string.endIndex {
            if string[idx] == "\u{1b}" {
                // Consume entire ANSI escape sequence
                let seqStart = idx
                idx = string.index(after: idx)
                if idx < string.endIndex, string[idx] == "[" {
                    idx = string.index(after: idx)
                    while idx < string.endIndex, !string[idx].isLetter {
                        idx = string.index(after: idx)
                    }
                    if idx < string.endIndex {
                        idx = string.index(after: idx) // consume the letter
                    }
                }
                result += string[seqStart ..< idx]
            } else {
                if visible >= maxWidth - 1 {
                    // Check if remaining visible chars would exceed maxWidth
                    var remaining = 0
                    var scan = idx
                    while scan < string.endIndex {
                        if string[scan] == "\u{1b}" {
                            scan = string.index(after: scan)
                            if scan < string.endIndex, string[scan] == "[" {
                                scan = string.index(after: scan)
                                while scan < string.endIndex, !string[scan].isLetter {
                                    scan = string.index(after: scan)
                                }
                                if scan < string.endIndex { scan = string.index(after: scan) }
                            }
                        } else {
                            remaining += 1
                            scan = string.index(after: scan)
                        }
                    }
                    if remaining > 1 {
                        result += "\u{2026}\(reset)"
                        return result
                    }
                }
                result.append(string[idx])
                visible += 1
                idx = string.index(after: idx)
            }
        }
        return result
    }

    /// Get terminal size (rows, cols).
    static func terminalSize() -> (rows: Int, cols: Int) {
        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 {
            return (Int(windowSize.ws_row), Int(windowSize.ws_col))
        }
        return (24, 80) // fallback
    }
}

// MARK: - Key Enum

enum Key: Equatable {
    case char(Character)
    case enter, escape, backspace, tab
    case cursorUp, cursorDown, cursorLeft, cursorRight
    case pageUp, pageDown
    case ctrlC, ctrlL
    case timeout, unknown
}
