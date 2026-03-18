import ArgumentParser
import Foundation

struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage plugin secrets in the macOS Keychain",
        subcommands: [SetCommand.self, DeleteCommand.self]
    )

    struct SetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Store a plugin secret in the Keychain (prompts for value)"
        )

        @Argument(help: "Plugin name (e.g. ghost)")
        var plugin: String

        @Argument(help: "Secret key (e.g. api-key)")
        var key: String

        func run() throws {
            print("Enter value for \(plugin)/\(key) (input hidden): ", terminator: "")
            guard let value = readLine(strippingNewline: true), !value.isEmpty else {
                throw ValidationError("No value entered")
            }
            let store = makeDefaultSecretStore()
            try store.setPluginSecret(plugin: plugin, key: key, value: value)
            print("Stored secret '\(key)' for plugin '\(plugin)'")
        }
    }

    struct DeleteCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Remove a plugin secret from the Keychain"
        )

        @Argument(help: "Plugin name (e.g. ghost)")
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
