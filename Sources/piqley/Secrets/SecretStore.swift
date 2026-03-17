import Foundation

protocol SecretStore {
    func get(key: String) throws -> String
    func set(key: String, value: String) throws
    func delete(key: String) throws
}

enum SecretStoreError: Error, LocalizedError {
    case notFound(key: String)
    case unexpectedError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .notFound(key):
            "Keychain secret not found for key: \(key)"
        case let .unexpectedError(status):
            "Keychain error: \(status)"
        }
    }

    var failureReason: String? {
        switch self {
        case .notFound: "No matching entry exists in the macOS Keychain."
        case .unexpectedError: "The Keychain returned an unexpected status code."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound: "Run 'piqley setup' to store your credentials in the Keychain."
        case .unexpectedError: "Check Keychain Access.app for permission issues or try unlocking the keychain."
        }
    }
}
