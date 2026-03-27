import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process and publish photos via plugins"
    )

    @Argument(help: "Workflow name (required when multiple workflows exist) or folder path")
    var firstArg: String

    @Argument(help: "Folder path (when first argument is a workflow name)")
    var secondArg: String?

    @Flag(help: "Preview without uploading or modifying anything")
    var dryRun = false

    @Flag(help: "Enable debug output from plugins")
    var debug = false

    @Flag(help: "Delete the contents of the source folder after a successful run")
    var deleteSourceContents = false

    @Flag(help: "Delete the source folder and its contents after a successful run")
    var deleteSourceFolder = false

    @Flag(help: "Overwrite source images with processed versions after a successful run")
    var overwriteSource = false

    @Flag(help: "Skip interactive prompts; drop invalid rules with warnings")
    var nonInteractive = false

    private var logger: Logger { Logger(label: "piqley.process") }

    func run() async throws {
        let (workflow, folderPath) = try resolveArguments()

        let sourceURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CleanError("Folder not found: \(folderPath)")
        }

        let lockPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.lock).path
        let lock = try ProcessLock(path: lockPath)
        defer { lock.release() }

        let secretStore = makeDefaultSecretStore()
        let stagesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.stages)
        let registry = try StageRegistry.load(from: stagesDir)
        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory,
            secretStore: secretStore,
            registry: registry
        )

        let succeeded = try await orchestrator.run(
            sourceURL: sourceURL, dryRun: dryRun, debug: debug,
            nonInteractive: nonInteractive, overwriteSource: overwriteSource
        )

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

    // MARK: - Argument Resolution

    private func resolveArguments() throws -> (Workflow, String) {
        // Two args provided: first is workflow name, second is folder path
        if let path = secondArg {
            let workflow = try WorkflowStore.load(name: firstArg)
            return (workflow, path)
        }

        // One arg: check if it matches a workflow name first
        let workflows = try WorkflowStore.list()

        if WorkflowStore.exists(name: firstArg) {
            throw ValidationError(
                "Workflow '\(firstArg)' found but no folder path provided.\n"
                    + "Usage: piqley process \(firstArg) <folder-path>"
            )
        }

        // Treat firstArg as the folder path
        if workflows.count == 1 {
            let workflow = try WorkflowStore.load(name: workflows[0])
            return (workflow, firstArg)
        }

        if workflows.isEmpty {
            throw CleanError("No workflows found. Run 'piqley setup' first.")
        }

        throw ValidationError(
            "Multiple workflows found: \(workflows.joined(separator: ", "))\n"
                + "Specify which workflow to use: piqley process <workflow> <folder-path>"
        )
    }
}
