import ArgumentParser
import Foundation

#if os(macOS)
    private let secretCommandAbstract = "Manage plugin secrets in the macOS Keychain"
    private let setCommandAbstract = "Store a plugin secret in the Keychain (prompts for value)"
    private let deleteCommandAbstract = "Remove a plugin secret from the Keychain"
#else
    private let secretCommandAbstract = "Manage plugin secrets in ~/.config/piqley/secrets.json"
    private let setCommandAbstract = "Store a plugin secret (prompts for value)"
    private let deleteCommandAbstract = "Remove a plugin secret"
#endif

struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: secretCommandAbstract,
        subcommands: [SetCommand.self, DeleteCommand.self, PruneCommand.self]
    )

    struct SetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: setCommandAbstract
        )

        @Argument(help: "Plugin name (e.g. my-uploader)")
        var plugin: String

        @Argument(help: "Secret key (e.g. api-key)")
        var key: String

        func run() throws {
            print("Enter value for \(plugin)/\(key) (input hidden): ", terminator: "")
            guard let value = readLine(strippingNewline: true), !value.isEmpty else {
                throw CleanError("No value entered")
            }
            let store = makeDefaultSecretStore()
            try store.setPluginSecret(plugin: plugin, key: key, value: value)
            print("Stored secret '\(key)' for plugin '\(plugin)'")
        }
    }

    struct DeleteCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: deleteCommandAbstract
        )

        @Argument(help: "Plugin name (e.g. my-uploader)")
        var plugin: String

        @Argument(help: "Secret key (e.g. api-key)")
        var key: String

        func run() throws {
            let store = makeDefaultSecretStore()
            try store.deletePluginSecret(plugin: plugin, key: key)
            print("Deleted secret '\(key)' for plugin '\(plugin)'")
        }
    }
}
