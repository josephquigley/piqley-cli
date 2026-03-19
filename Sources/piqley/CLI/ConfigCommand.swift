import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Open the piqley config file in your editor"
    )

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(PiqleyPath.config).path

        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ValidationError("Config file not found at \(configPath)\nRun 'piqley setup' first.")
        }

        try openInEditor(configPath)
    }
}

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
        throw ValidationError("Editor exited with status \(process.terminationStatus)")
    }
}
