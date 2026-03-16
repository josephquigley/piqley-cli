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
        case .notFound(let key):
            return "Secret not found for key: \(key)"
        case .unexpectedError(let status):
            return "Keychain error: \(status)"
        }
    }
}
