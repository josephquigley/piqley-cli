import Foundation
import PiqleyCore

enum BinaryProbeResult: Equatable {
    case piqleyPlugin(schemaVersion: String)
    case cliTool
    case notFound
    case notExecutable
}

enum BinaryProbe {
    /// Probe a binary to determine if it's a piqley SDK plugin or a regular CLI tool.
    /// - Parameters:
    ///   - command: The command string from HookConfig (relative or absolute path)
    ///   - pluginDirectory: The plugin's directory for resolving relative paths
    ///   - fileManager: The file system manager to use
    /// - Returns: The probe result
    static func probe(
        command: String, pluginDirectory: URL,
        fileManager: any FileSystemManager = FileManager.default
    ) -> BinaryProbeResult {
        let resolvedPath = resolveExecutable(command, pluginDirectory: pluginDirectory)

        guard fileManager.fileExists(atPath: resolvedPath) else {
            return .notFound
        }
        guard fileManager.isExecutableFile(atPath: resolvedPath) else {
            return .notExecutable
        }

        // Run with --piqley-info and check response
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = ["--piqley-info"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .cliTool
        }

        // Wait with 5 second timeout using a semaphore
        let semaphore = DispatchSemaphore(value: 0)
        let proc = process // capture immutable ref for Sendable closure
        DispatchQueue.global().async {
            proc.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .seconds(5)) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return .cliTool
        }

        guard process.terminationStatus == 0 else {
            return .cliTool
        }

        let data = stdoutPipe.fileHandleForReading.availableData
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["piqleyPlugin"] as? Bool == true,
              let schemaVersion = json["schemaVersion"] as? String
        else {
            return .cliTool
        }

        return .piqleyPlugin(schemaVersion: schemaVersion)
    }

    /// Resolve executable path (same logic as PluginRunner.resolveExecutable).
    static func resolveExecutable(_ command: String, pluginDirectory: URL) -> String {
        if command.hasPrefix("/") { return command }
        return pluginDirectory.appendingPathComponent(command).path
    }
}
