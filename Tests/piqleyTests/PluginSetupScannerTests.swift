import Foundation
import PiqleyCore
import Testing

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
    func list() throws -> [String] { Array(secrets.keys) }
}

// MARK: - Helpers

private func makeConfigStore(_ dir: URL, fm: any FileSystemManager) -> BasePluginConfigStore {
    BasePluginConfigStore(directory: dir, fileManager: fm)
}

private func makeLoadedPlugin(name: String, manifest: PluginManifest, dir: URL) -> LoadedPlugin {
    LoadedPlugin(identifier: manifest.identifier, name: name, directory: dir, manifest: manifest, stages: [:])
}

// MARK: - Tests

@Suite("PluginSetupScanner")
struct PluginSetupScannerTests {

    // MARK: 1. promptRequiredValue

    @Test("null default requires input and stores value in base config")
    func promptRequiredValue() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null, metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)
        let inputSource = MockInputSource(responses: ["https://example.com"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["api-url"] == JSONValue.string("https://example.com"))
    }

    // MARK: 2. acceptDefault

    @Test("empty input accepts non-null default value")
    func acceptDefault() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.value(key: "port", type: .int, value: .number(8080), metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)
        let inputSource = MockInputSource(responses: [""]) // empty -> accept default
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["port"] == JSONValue.number(8080))
    }

    // MARK: 3. existingValueAsDefault

    @Test("existing config values are offered as defaults -- Enter keeps them")
    func existingValueAsDefault() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null, metadata: ConfigMetadata())],
            setup: nil
        )

        // Pre-write base config with existing value
        let configStore = makeConfigStore(configDir, fm: fm)
        let existingConfig = BasePluginConfig(values: ["api-url": JSONValue.string("https://existing.com")])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        // Empty input: accept existing value as default
        let inputSource = MockInputSource(responses: [""])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["api-url"] == JSONValue.string("https://existing.com"))
    }

    @Test("existing config values can be overridden with new input")
    func overrideExistingValue() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null, metadata: ConfigMetadata())],
            setup: nil
        )

        let configStore = makeConfigStore(configDir, fm: fm)
        let existingConfig = BasePluginConfig(values: ["api-url": JSONValue.string("https://old.com")])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let inputSource = MockInputSource(responses: ["https://new.com"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["api-url"] == JSONValue.string("https://new.com"))
    }

    // MARK: 4. forceResetValues

    @Test("force flag clears existing values and re-prompts")
    func forceResetValues() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.value(key: "api-url", type: .string, value: .null, metadata: ConfigMetadata())],
            setup: nil
        )

        // Pre-write base config with existing value
        let configStore = makeConfigStore(configDir, fm: fm)
        let existingConfig = BasePluginConfig(values: ["api-url": JSONValue.string("https://old.com")])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let inputSource = MockInputSource(responses: ["https://new.com"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin, force: true)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["api-url"] == JSONValue.string("https://new.com"))
    }

    // MARK: 5. repromptInvalidInt

    @Test("invalid int input reprompts until valid input is given")
    func repromptInvalidInt() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.value(key: "count", type: .int, value: .null, metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)
        // "notanint" is invalid, "42" is valid
        let inputSource = MockInputSource(responses: ["notanint", "42"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["count"] == JSONValue.number(42))
    }

    // MARK: 6. promptMissingSecret

    @Test("missing secret prompts user and stores with alias key")
    func promptMissingSecret() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.secret(secretKey: "api-token", type: .string, metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)
        let inputSource = MockInputSource(responses: ["super-secret-token"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        // Secret stored under alias key
        let alias = "com.test.test-plugin-api-token"
        let stored = try secretStore.get(key: alias)
        #expect(stored == "super-secret-token")

        // Alias mapping stored in base config
        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.secrets["api-token"] == alias)
    }

    // MARK: 7. existingSecretAsDefault

    @Test("existing secret is kept when Enter is pressed")
    func existingSecretAsDefault() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.secret(secretKey: "api-token", type: .string, metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)

        // Pre-store secret under alias and map it in base config
        let alias = "com.test.test-plugin-api-token"
        try secretStore.set(key: alias, value: "existing-token")
        let existingConfig = BasePluginConfig(secrets: ["api-token": alias])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        // Empty input: keep existing secret
        let inputSource = MockInputSource(responses: [""])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let stored = try secretStore.get(key: alias)
        #expect(stored == "existing-token")
    }

    @Test("existing secret can be revealed with ? then kept with Enter")
    func revealExistingSecret() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.secret(secretKey: "api-token", type: .string, metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)

        let alias = "com.test.test-plugin-api-token"
        try secretStore.set(key: alias, value: "existing-token")
        let existingConfig = BasePluginConfig(secrets: ["api-token": alias])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        // "?" reveals, then "" keeps existing
        let inputSource = MockInputSource(responses: ["?", ""])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let stored = try secretStore.get(key: alias)
        #expect(stored == "existing-token")
    }

    @Test("existing secret can be overridden with new input")
    func overrideExistingSecret() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [.secret(secretKey: "api-token", type: .string, metadata: ConfigMetadata())],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)

        let alias = "com.test.test-plugin-api-token"
        try secretStore.set(key: alias, value: "old-token")
        let existingConfig = BasePluginConfig(secrets: ["api-token": alias])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        let inputSource = MockInputSource(responses: ["new-token"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let stored = try secretStore.get(key: alias)
        #expect(stored == "new-token")
    }

    // MARK: 8. setupBinaryNotFound

    @Test("non-existent setup binary leaves isSetUp as nil in base config")
    func setupBinaryNotFound() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [],
            setup: SetupConfig(command: "/non/existent/binary")
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)
        let inputSource = MockInputSource(responses: [])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.isSetUp == nil)
    }

    // MARK: 9. skipValueKeys

    @Test("skipValueKeys skips prompting for specified config keys")
    func skipValueKeys() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [
                .value(key: "kept-url", type: .string, value: .null, metadata: ConfigMetadata()),
                .value(key: "new-key", type: .string, value: .null, metadata: ConfigMetadata()),
            ],
            setup: nil
        )

        // Pre-write config with existing value for kept-url
        let configStore = makeConfigStore(configDir, fm: fm)
        let existingConfig = BasePluginConfig(values: ["kept-url": .string("https://existing.com")])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        // Only one response needed: for new-key (kept-url is skipped)
        let inputSource = MockInputSource(responses: ["new-value"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin, skipValueKeys: ["kept-url"])

        let config = try configStore.load(for: "com.test.test-plugin")
        #expect(config?.values["kept-url"] == .string("https://existing.com"))
        #expect(config?.values["new-key"] == .string("new-value"))
    }

    // MARK: 10. noHeaderForEmptyConfig

    @Test("plugin with no config entries and no setup binary does not print header")
    func noHeaderForEmptyConfig() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.empty-plugin",
            name: "empty-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "empty-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)
        let inputSource = MockInputSource(responses: [])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        // Should complete without printing "empty-plugin:" header
        try scanner.scan(plugin: plugin)

        let config = try configStore.load(for: "com.test.empty-plugin")
        #expect(config != nil)
    }

    // MARK: 11. skipSecretKeys

    @Test("skipSecretKeys skips prompting for specified secret keys")
    func skipSecretKeys() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let dir = URL(fileURLWithPath: "/test/plugin")
        let manifest = PluginManifest(
            identifier: "com.test.test-plugin",
            name: "test-plugin",
            type: .static,
            pluginSchemaVersion: "1",
            config: [
                .secret(secretKey: "kept-token", type: .string, metadata: ConfigMetadata()),
                .secret(secretKey: "new-token", type: .string, metadata: ConfigMetadata()),
            ],
            setup: nil
        )

        let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
        let secretStore = MockSecretStore()
        let configStore = makeConfigStore(configDir, fm: fm)

        // Pre-store kept-token
        let alias = "com.test.test-plugin-kept-token"
        try secretStore.set(key: alias, value: "existing-secret")
        let existingConfig = BasePluginConfig(secrets: ["kept-token": alias])
        try configStore.save(existingConfig, for: "com.test.test-plugin")

        // Only one response needed: for new-token (kept-token is skipped)
        let inputSource = MockInputSource(responses: ["new-secret-value"])
        var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource, fileManager: fm)
        try scanner.scan(plugin: plugin, skipSecretKeys: ["kept-token"])

        let stored = try secretStore.get(key: alias)
        #expect(stored == "existing-secret")

        let config = try configStore.load(for: "com.test.test-plugin")
        let newAlias = "com.test.test-plugin-new-token"
        #expect(config?.secrets["new-token"] == newAlias)
        let newStored = try secretStore.get(key: newAlias)
        #expect(newStored == "new-secret-value")
    }
}
