import Testing
import Foundation
import PiqleyCore
@testable import piqley

// MARK: - Test helpers

/// Mock input source that returns canned responses in order.
struct MockInputSource: InputSource {
    var responses: [String]
    private var index = 0

    init(responses: [String]) {
        self.responses = responses
    }

    mutating func readLine() -> String? {
        guard index < responses.count else { return nil }
        defer { index += 1 }
        return responses[index]
    }
}

/// In-memory secret store for testing.
final class MockSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }
    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
}

// MARK: - Helpers

private func makePluginDir(name: String, manifest: PluginManifest) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-scanner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
}

private func makeLoadedPlugin(name: String, manifest: PluginManifest, dir: URL) -> LoadedPlugin {
    LoadedPlugin(identifier: manifest.identifier, name: name, directory: dir, manifest: manifest, stages: [:])
}

private func loadConfig(from dir: URL) throws -> PluginConfig {
    let url = dir.appendingPathComponent("config.json")
    return try PluginConfig.load(from: url)
}

// MARK: - Tests

@Suite("PluginSetupScanner")
struct PluginSetupScannerTests {

    // MARK: 1. promptRequiredValue — null default requires input, stores in sidecar

    @Test("null default requires input and stores value in config.json")
    func promptRequiredValue() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null)],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let inputSource = MockInputSource(responses: ["https://example.com"])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let config = try loadConfig(from: dir)
        #expect(config.values["api-url"] == JSONValue.string("https://example.com"))
    }

    // MARK: 2. acceptDefault — empty input accepts default

    @Test("empty input accepts non-null default value")
    func acceptDefault() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.value(key: "port", type: .int, value: .number(8080))],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let inputSource = MockInputSource(responses: [""])  // empty → accept default
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let config = try loadConfig(from: dir)
        #expect(config.values["port"] == JSONValue.number(8080))
    }

    // MARK: 3. skipExistingValues — value already in sidecar is not re-prompted

    @Test("existing config values are not re-prompted")
    func skipExistingValues() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null)],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-write config.json with existing value
        let existingConfig = PluginConfig(values: ["api-url": JSONValue.string("https://existing.com")])
        try existingConfig.save(to: dir.appendingPathComponent("config.json"))

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        // No responses needed — should not prompt
        let inputSource = MockInputSource(responses: [])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let config = try loadConfig(from: dir)
        #expect(config.values["api-url"] == JSONValue.string("https://existing.com"))
    }

    // MARK: 4. forceResetValues — force flag clears existing values

    @Test("force flag clears existing values and re-prompts")
    func forceResetValues() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null)],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-write config.json with existing value
        let existingConfig = PluginConfig(values: ["api-url": JSONValue.string("https://old.com")])
        try existingConfig.save(to: dir.appendingPathComponent("config.json"))

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let inputSource = MockInputSource(responses: ["https://new.com"])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin, force: true)

        let config = try loadConfig(from: dir)
        #expect(config.values["api-url"] == JSONValue.string("https://new.com"))
    }

    // MARK: 5. repromptInvalidInt — first invalid, second valid

    @Test("invalid int input reprompts until valid input is given")
    func repromptInvalidInt() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.value(key: "count", type: .int, value: .null)],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        // "notanint" is invalid, "42" is valid
        let inputSource = MockInputSource(responses: ["notanint", "42"])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let config = try loadConfig(from: dir)
        #expect(config.values["count"] == JSONValue.number(42))
    }

    // MARK: 6. promptMissingSecret — not in keychain, prompts and stores

    @Test("missing secret prompts user and stores in secret store")
    func promptMissingSecret() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.secret(secretKey: "api-token", type: .string)],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()  // empty — no secret pre-stored
        let inputSource = MockInputSource(responses: ["super-secret-token"])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let stored = try secretStore.getPluginSecret(plugin: "com.test.test-plugin", key: "api-token")
        #expect(stored == "super-secret-token")
    }

    // MARK: 7. skipExistingSecret — already in keychain, not prompted

    @Test("existing keychain secret is not re-prompted")
    func skipExistingSecret() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [.secret(secretKey: "api-token", type: .string)],
            setup: nil
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        // Pre-store the secret under the identifier (reverse TLD)
        try secretStore.setPluginSecret(plugin: "com.test.test-plugin", key: "api-token", value: "existing-token")

        // No responses — should not be prompted
        let inputSource = MockInputSource(responses: [])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let stored = try secretStore.getPluginSecret(plugin: "com.test.test-plugin", key: "api-token")
        #expect(stored == "existing-token")
    }

    // MARK: 8. setupBinaryNotFound — non-existent binary, isSetUp stays nil

    @Test("non-existent setup binary leaves isSetUp as nil in config.json")
    func setupBinaryNotFound() throws {
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            pluginProtocolVersion: "1",
            config: [],
            setup: SetupConfig(command: "/non/existent/binary")
        )
        let dir = try makePluginDir(name: "test-plugin", manifest: manifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let inputSource = MockInputSource(responses: [])
        var scanner = PluginSetupScanner(secretStore: secretStore, inputSource: inputSource)
        try scanner.scan(plugin: plugin)

        let config = try loadConfig(from: dir)
        #expect(config.isSetUp == nil)
    }
}
