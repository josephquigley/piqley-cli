import ArgumentParser
import Foundation

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process and publish photos via plugins"
    )

    @Argument(help: "Path to folder containing images to process")
    var folderPath: String

    @Flag(help: "Preview without uploading or emailing")
    var dryRun = false

    @Flag(help: "Delete source image files after successful run")
    var deleteSourceImages = false

    @Flag(help: "Delete source folder after successful run")
    var deleteSourceFolder = false

    func run() async throws {
        print("Not yet implemented")
    }
}
