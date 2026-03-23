import Foundation
import Testing

@testable import piqley

/// In-memory secret store for testing list() contract.
private final class TestSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }

    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
    func list() throws -> [String] { Array(secrets.keys) }
}

@Suite("SecretStore list")
struct SecretStoreListTests {
    @Test("list returns all stored keys")
    func listAllKeys() throws {
        let store = TestSecretStore()
        try store.set(key: "alpha", value: "a")
        try store.set(key: "beta", value: "b")

        let keys = try store.list()
        #expect(keys.sorted() == ["alpha", "beta"])
    }

    @Test("list returns empty when no secrets stored")
    func listEmpty() throws {
        let store = TestSecretStore()
        let keys = try store.list()
        #expect(keys.isEmpty)
    }

    @Test("list reflects deletions")
    func listAfterDelete() throws {
        let store = TestSecretStore()
        try store.set(key: "alpha", value: "a")
        try store.set(key: "beta", value: "b")
        try store.delete(key: "alpha")

        let keys = try store.list()
        #expect(keys == ["beta"])
    }
}
