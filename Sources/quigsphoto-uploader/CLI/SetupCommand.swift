import ArgumentParser

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup — configure Ghost, SMTP, and processing settings"
    )

    func run() throws {
        print("Running setup...")
    }
}
