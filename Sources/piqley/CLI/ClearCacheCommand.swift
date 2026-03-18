import ArgumentParser

struct ClearCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-cache",
        abstract: "Clear plugin execution logs"
    )

    @Option(help: "Clear only this plugin's execution log")
    var plugin: String?

    func run() throws {
        print("Not yet implemented")
    }
}
