import ArgumentParser

@main
struct QuigsphotoUploader: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quigsphoto-uploader",
        abstract: "Process and publish photos to Ghost CMS",
        subcommands: [ProcessCommand.self, SetupCommand.self]
    )
}
