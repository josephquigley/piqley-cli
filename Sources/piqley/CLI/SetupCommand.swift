import ArgumentParser

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up piqley configuration and install bundled plugins"
    )
    func run() async throws {
        print("Not yet implemented")
    }
}
