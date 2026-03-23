import Foundation

func openInEditor(_ path: String) throws {
    let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [editor, path]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw CleanError("Editor exited with status \(process.terminationStatus)")
    }
}
