import ArgumentParser
import PiqleyCore

struct PluginRulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Manage rules for a plugin.",
        subcommands: [PluginRulesEditCommand.self],
        defaultSubcommand: PluginRulesEditCommand.self
    )
}

struct PluginRulesEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Interactively edit rules for a plugin."
    )

    @Argument(help: "The plugin identifier to edit rules for.")
    var pluginID: String

    func run() async throws {
        print("Rule editor for \(pluginID) — not yet implemented.")
    }
}
