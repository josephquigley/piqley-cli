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
