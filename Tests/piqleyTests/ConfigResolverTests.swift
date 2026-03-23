import Foundation
import PiqleyCore
import Testing

@testable import piqley

/// In-memory secret store for ConfigResolver tests.
private final class ConfigResolverMockSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }

    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
    func list() throws -> [String] { Array(secrets.keys) }
}

@Suite("ConfigResolver")
struct ConfigResolverTests {
    @Test("Resolves config with no workflow overrides")
    func noOverrides() throws {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com")],
            secrets: ["API_KEY": "prod-key"]
        )
        let secrets = ConfigResolverMockSecretStore()
        try secrets.set(key: "prod-key", value: "secret123")

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: nil,
            secretStore: secrets
        )
        #expect(resolved.values["url"] == .string("https://prod.com"))
        #expect(resolved.secrets["API_KEY"] == "secret123")
    }

    @Test("Workflow overrides replace base values")
    func withOverrides() throws {
        let base = BasePluginConfig(
            values: ["url": .string("https://prod.com"), "quality": .number(85)],
            secrets: ["API_KEY": "prod-key"]
        )
        let overrides = WorkflowPluginConfig(
            values: ["url": .string("https://staging.com")],
            secrets: ["API_KEY": "staging-key"]
        )
        let secrets = ConfigResolverMockSecretStore()
        try secrets.set(key: "staging-key", value: "staging-secret")

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: overrides,
            secretStore: secrets
        )
        #expect(resolved.values["url"] == .string("https://staging.com"))
        #expect(resolved.values["quality"] == .number(85))
        #expect(resolved.secrets["API_KEY"] == "staging-secret")
    }

    @Test("Builds environment variables with correct prefixes")
    func environmentVariables() throws {
        let base = BasePluginConfig(
            values: ["site-url": .string("https://example.com")],
            secrets: ["API_KEY": "key-alias"]
        )
        let secrets = ConfigResolverMockSecretStore()
        try secrets.set(key: "key-alias", value: "secret-value")

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: nil,
            secretStore: secrets
        )
        let env = resolved.toEnvironment()
        #expect(env["PIQLEY_CONFIG_SITE_URL"] == "https://example.com")
        #expect(env["PIQLEY_SECRET_API_KEY"] == "secret-value")
    }

    @Test("sanitizeKey uppercases and replaces hyphens and dots with underscores")
    func sanitizeKeyBasic() {
        #expect(ResolvedPluginConfig.sanitizeKey("site-url") == "SITE_URL")
        #expect(ResolvedPluginConfig.sanitizeKey("my.config.key") == "MY_CONFIG_KEY")
        #expect(ResolvedPluginConfig.sanitizeKey("simple") == "SIMPLE")
    }

    @Test("sanitizeKey strips non-alphanumeric characters except underscores")
    func sanitizeKeySpecialChars() {
        #expect(ResolvedPluginConfig.sanitizeKey("key@#$name") == "KEYNAME")
        #expect(ResolvedPluginConfig.sanitizeKey("a-b.c!d") == "A_B_CD")
    }

    @Test("Secret alias resolution throws when alias not found in store")
    func secretAliasNotFound() throws {
        let base = BasePluginConfig(
            values: [:],
            secrets: ["API_KEY": "nonexistent-alias"]
        )
        let secrets = ConfigResolverMockSecretStore()

        #expect(throws: SecretStoreError.self) {
            _ = try ConfigResolver.resolve(
                base: base,
                workflowOverrides: nil,
                secretStore: secrets
            )
        }
    }

    @Test("toEnvironment handles all JSONValue types")
    func environmentValueTypes() throws {
        let base = BasePluginConfig(
            values: [
                "str": .string("hello"),
                "num": .number(42),
                "float": .number(3.14),
                "flag": .bool(true),
                "nothing": .null,
            ],
            secrets: [:]
        )
        let secrets = ConfigResolverMockSecretStore()

        let resolved = try ConfigResolver.resolve(
            base: base,
            workflowOverrides: nil,
            secretStore: secrets
        )
        let env = resolved.toEnvironment()
        #expect(env["PIQLEY_CONFIG_STR"] == "hello")
        #expect(env["PIQLEY_CONFIG_NUM"] == "42")
        #expect(env["PIQLEY_CONFIG_FLOAT"] == "3.14")
        #expect(env["PIQLEY_CONFIG_FLAG"] == "true")
        #expect(env["PIQLEY_CONFIG_NOTHING"] == "")
    }
}
