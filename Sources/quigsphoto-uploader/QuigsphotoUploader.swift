import ArgumentParser

@main
struct QuigsphotoUploader: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quigsphoto-uploader",
        abstract: "Process and publish photos to Ghost CMS",
        subcommands: [ProcessCommand.self, SetupCommand.self]
    )
}
