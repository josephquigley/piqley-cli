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

    @Flag(help: "Delete source image files after a successful run")
    var deleteSourceImages = false

    @Flag(help: "Delete source folder after a successful run (implies --delete-source-images)")
    var deleteSourceFolder = false

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

        let secretStore = KeychainSecretStore()
        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory,
            secretStore: secretStore
        )

        let succeeded = try await orchestrator.run(sourceURL: sourceURL, dryRun: dryRun)

        if succeeded, !dryRun {
            if deleteSourceFolder {
                logger.info("Deleting source folder: \(sourceURL.path)")
                try FileManager.default.removeItem(at: sourceURL)
            } else if deleteSourceImages {
                logger.info("Deleting source images from: \(sourceURL.path)")
                let contents = try FileManager.default.contentsOfDirectory(
                    at: sourceURL, includingPropertiesForKeys: nil
                )
                for file in contents where TempFolder.imageExtensions.contains(file.pathExtension.lowercased()) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }

        if !succeeded {
            throw ExitCode(1)
        }
    }
}
