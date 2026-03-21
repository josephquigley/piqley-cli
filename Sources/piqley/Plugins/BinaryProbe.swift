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
    /// - Returns: The probe result
    static func probe(command: String, pluginDirectory: URL) -> BinaryProbeResult {
        let resolvedPath = resolveExecutable(command, pluginDirectory: pluginDirectory)

        let fileManager = FileManager.default
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

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .cliTool
        }

        // 5 second timeout
        let deadline = DispatchTime.now() + .seconds(5)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return .cliTool
        }

        guard process.terminationStatus == 0 else {
            return .cliTool
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
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
