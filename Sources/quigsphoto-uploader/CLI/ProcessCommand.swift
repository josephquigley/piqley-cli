import ArgumentParser

struct ProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process all images in a folder and publish to Ghost CMS"
    )

    @Argument(help: "Path to folder containing exported images")
    var folderPath: String

    @Flag(help: "Preview actions without uploading or emailing")
    var dryRun = false

    @Flag(help: "Include successful images in result output")
    var verboseResults = false

    @Flag(help: "Write a single JSON results file instead of individual text files")
    var jsonResults = false

    @Option(help: "Directory to write result files to (default: input folder)")
    var resultsDir: String?

    func run() throws {
        print("Processing folder: \(folderPath)")
    }
}
