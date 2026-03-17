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
            "Secret not found for key: \(key)"
        case let .unexpectedError(status):
            "Keychain error: \(status)"
        }
    }
}
