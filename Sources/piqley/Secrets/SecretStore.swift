import Foundation

protocol SecretStore: Sendable {
    func get(key: String) throws -> String
    func set(key: String, value: String) throws
    func delete(key: String) throws
}

extension SecretStore {
    /// Fetch a plugin-scoped secret. Key is namespaced as `piqley.plugins.<plugin>.<key>`.
    func getPluginSecret(plugin: String, key: String) throws -> String {
        try get(key: pluginSecretKey(plugin: plugin, key: key))
    }

    func setPluginSecret(plugin: String, key: String, value: String) throws {
        try set(key: pluginSecretKey(plugin: plugin, key: key), value: value)
    }

    func deletePluginSecret(plugin: String, key: String) throws {
        try delete(key: pluginSecretKey(plugin: plugin, key: key))
    }

    private func pluginSecretKey(plugin: String, key: String) -> String {
        "piqley.plugins.\(plugin).\(key)"
    }
}

enum SecretStoreError: Error, LocalizedError {
    case notFound(key: String)
    case unexpectedError(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .notFound(key):
            #if os(macOS)
                "Keychain secret not found for key: \(key)"
            #else
                "Secret not found for key: \(key)"
            #endif
        case let .unexpectedError(status):
            #if os(macOS)
                "Keychain error: \(status)"
            #else
                "Secret store error: \(status)"
            #endif
        }
    }

    var failureReason: String? {
        switch self {
        case .notFound:
            #if os(macOS)
                "No matching entry exists in the macOS Keychain."
            #else
                "No matching entry exists in the secrets file."
            #endif
        case .unexpectedError:
            #if os(macOS)
                "The Keychain returned an unexpected status code."
            #else
                "The secret store encountered an unexpected error."
            #endif
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound:
            "Run 'piqley secret set <plugin> <key>' to store the credential."
        case .unexpectedError:
            #if os(macOS)
                "Check Keychain Access.app for permission issues."
            #else
                "Check that ~/.config/piqley/secrets.json is readable."
            #endif
        }
    }
}
