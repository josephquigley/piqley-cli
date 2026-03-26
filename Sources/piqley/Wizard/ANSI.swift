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
