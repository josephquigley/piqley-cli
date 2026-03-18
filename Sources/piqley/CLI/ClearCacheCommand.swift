import ArgumentParser
import Foundation
import Logging

struct ClearCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-cache",
        abstract: "Clear plugin execution logs"
    )

    @Option(help: "Clear only this plugin's execution log (by plugin name)")
    var plugin: String?

    private var logger: Logger { Logger(label: "piqley.clear-cache") }

    func run() throws {
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

        if let pluginName = plugin {
            let logPath = pluginsDir
                .appendingPathComponent(pluginName)
                .appendingPathComponent(PluginFile.executionLog)
            try clearLog(at: logPath, label: pluginName)
        } else {
            // Clear all plugin execution logs
            guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
                print("No plugins directory found at \(pluginsDir.path)")
                return
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]
            )
            for pluginDir in contents where (try? pluginDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let logPath = pluginDir.appendingPathComponent(PluginFile.executionLog)
                try clearLog(at: logPath, label: pluginDir.lastPathComponent)
            }
        }
    }

    private func clearLog(at url: URL, label: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[\(label)] No execution log found")
            return
        }
        try FileManager.default.removeItem(at: url)
        print("[\(label)] Execution log cleared")
    }
}
