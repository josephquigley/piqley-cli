import ArgumentParser
import Foundation
import Logging

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process and publish photos via plugins"
    )

    @Argument(help: "Path to folder containing images to process")
    var folderPath: String

    @Flag(help: "Preview without uploading or modifying anything")
    var dryRun = false

    @Flag(help: "Delete the contents of the source folder after a successful run")
    var deleteSourceContents = false

    @Flag(help: "Delete the source folder and its contents after a successful run")
    var deleteSourceFolder = false

    @Flag(help: "Skip interactive prompts; drop invalid rules with warnings")
    var nonInteractive = false

    private var logger: Logger { Logger(label: "piqley.process") }

    func run() async throws {
        let sourceURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ValidationError("Folder not found: \(folderPath)")
        }

        let lockPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/piqley.lock").path
        let lock = try ProcessLock(path: lockPath)
        defer { lock.release() }

        let config: AppConfig
        do {
            config = try AppConfig.load()
        } catch {
            throw ValidationError("Failed to load config: \(formatError(error))\nRun 'piqley setup' to create a config.")
        }

        let secretStore = makeDefaultSecretStore()
        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory,
            secretStore: secretStore
        )

        let succeeded = try await orchestrator.run(sourceURL: sourceURL, dryRun: dryRun, nonInteractive: nonInteractive)

        if succeeded, !dryRun {
            if deleteSourceFolder {
                logger.info("Deleting source folder: \(sourceURL.path)")
                try FileManager.default.removeItem(at: sourceURL)
            } else if deleteSourceContents {
                logger.info("Deleting contents of source folder: \(sourceURL.path)")
                let contents = try FileManager.default.contentsOfDirectory(
                    at: sourceURL, includingPropertiesForKeys: nil
                )
                for file in contents {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }

        if !succeeded {
            throw ExitCode(1)
        }
    }
}
