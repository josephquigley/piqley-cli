# Plugin Update Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `piqley plugin update` command that replaces plugin files from a new `.piqleyplugin` zip while merging config/secrets intelligently.

**Architecture:** New `UpdateCommand.swift` file with `PluginUpdater` enum (extraction/validation/file replacement), `ConfigMerger` enum (config diffing), and `UpdateSubcommand` struct (orchestration). `PluginSetupScanner` gains `skipValueKeys`/`skipSecretKeys` parameters to control which entries get prompted.

**Tech Stack:** Swift 6, ArgumentParser, PiqleyCore, Swift Testing

**Spec:** `docs/superpowers/specs/2026-03-25-plugin-update-command-design.md`

---

### Task 1: Add `skipValueKeys`/`skipSecretKeys` to PluginSetupScanner

**Files:**
- Modify: `Sources/piqley/Plugins/PluginSetupScanner.swift:25-89`
- Test: `Tests/piqleyTests/PluginSetupScannerTests.swift`

- [ ] **Step 1: Write the failing test for skipValueKeys**

In `Tests/piqleyTests/PluginSetupScannerTests.swift`, add at the end of the `PluginSetupScannerTests` suite:

```swift
// MARK: 9. skipValueKeys

@Test("skipValueKeys skips prompting for specified config keys")
func skipValueKeys() throws {
    let configDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: configDir) }
    let manifest = PluginManifest(
        identifier: "com.test.test-plugin",
        name: "test-plugin",
        pluginSchemaVersion: "1",
        config: [
            .value(key: "kept-url", type: .string, value: .null),
            .value(key: "new-key", type: .string, value: .null),
        ],
        setup: nil
    )
    let dir = try makePluginDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Pre-write config with existing value for kept-url
    let configStore = makeConfigStore(configDir)
    let existingConfig = BasePluginConfig(values: ["kept-url": .string("https://existing.com")])
    try configStore.save(existingConfig, for: "com.test.test-plugin")

    let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
    let secretStore = MockSecretStore()
    // Only one response needed: for new-key (kept-url is skipped)
    let inputSource = MockInputSource(responses: ["new-value"])
    var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource)
    try scanner.scan(plugin: plugin, skipValueKeys: ["kept-url"])

    let config = try configStore.load(for: "com.test.test-plugin")
    #expect(config?.values["kept-url"] == .string("https://existing.com"))
    #expect(config?.values["new-key"] == .string("new-value"))
}
```

- [ ] **Step 2: Write the failing test for skipSecretKeys**

```swift
// MARK: 10. skipSecretKeys

@Test("skipSecretKeys skips prompting for specified secret keys")
func skipSecretKeys() throws {
    let configDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: configDir) }
    let manifest = PluginManifest(
        identifier: "com.test.test-plugin",
        name: "test-plugin",
        pluginSchemaVersion: "1",
        config: [
            .secret(secretKey: "kept-token", type: .string),
            .secret(secretKey: "new-token", type: .string),
        ],
        setup: nil
    )
    let dir = try makePluginDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let plugin = makeLoadedPlugin(name: "test-plugin", manifest: manifest, dir: dir)
    let secretStore = MockSecretStore()
    let configStore = makeConfigStore(configDir)

    // Pre-store kept-token
    let alias = "com.test.test-plugin-kept-token"
    try secretStore.set(key: alias, value: "existing-secret")
    let existingConfig = BasePluginConfig(secrets: ["kept-token": alias])
    try configStore.save(existingConfig, for: "com.test.test-plugin")

    // Only one response needed: for new-token (kept-token is skipped)
    let inputSource = MockInputSource(responses: ["new-secret-value"])
    var scanner = PluginSetupScanner(secretStore: secretStore, configStore: configStore, inputSource: inputSource)
    try scanner.scan(plugin: plugin, skipSecretKeys: ["kept-token"])

    let stored = try secretStore.get(key: alias)
    #expect(stored == "existing-secret")

    let config = try configStore.load(for: "com.test.test-plugin")
    let newAlias = "com.test.test-plugin-new-token"
    #expect(config?.secrets["new-token"] == newAlias)
    let newStored = try secretStore.get(key: newAlias)
    #expect(newStored == "new-secret-value")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter PluginSetupScannerTests 2>&1`
Expected: compilation error, `scan` does not accept `skipValueKeys`/`skipSecretKeys` parameters.

- [ ] **Step 4: Add skipValueKeys/skipSecretKeys parameters to scan()**

In `Sources/piqley/Plugins/PluginSetupScanner.swift`, change the `scan` method signature from:

```swift
mutating func scan(plugin: LoadedPlugin, force: Bool = false) throws {
```

to:

```swift
mutating func scan(
    plugin: LoadedPlugin,
    force: Bool = false,
    skipValueKeys: Set<String> = [],
    skipSecretKeys: Set<String> = []
) throws {
```

Then in Phase 1 (the `for entry in plugin.manifest.config` loop that handles `.value`), add a skip check right after the `guard case let .value(key, type, defaultValue) = entry else { continue }` line, before the existing `!force` check:

```swift
if skipValueKeys.contains(key) {
    continue
}
```

In Phase 2 (the loop that handles `.secret`), add a skip check right after the `guard case let .secret(secretKey, _) = entry else { continue }` line:

```swift
if skipSecretKeys.contains(secretKey) {
    continue
}
```

- [ ] **Step 5: Run all tests to verify they pass and no regressions**

Run: `swift test 2>&1`
Expected: all tests pass, including the 2 new scanner tests and all existing tests.

- [ ] **Step 6: Commit**

Commit message: `feat: add skipValueKeys/skipSecretKeys to PluginSetupScanner`

---

### Task 2: Create UpdateError enum and PluginUpdater

**Files:**
- Create: `Sources/piqley/CLI/UpdateCommand.swift`
- Test: `Tests/piqleyTests/UpdateCommandTests.swift`

This task creates the `UpdateError` enum and the `PluginUpdater.update()` static method. The updater handles extraction, validation, old manifest reading, and file replacement. It does NOT handle config merging (that's Task 3).

Note: The `identifierMismatch` case from the spec is unnecessary. The updater derives the plugin identity from the zip's manifest, then checks if that identifier is installed. If someone updates with a zip containing a different identifier, the installed directory simply won't exist, and `notInstalled` is the correct error. The spec's step 10 (verify identifier match) is satisfied by step 8's install check.

- [ ] **Step 1: Write tests for PluginUpdater error cases and success path**

Create `Tests/piqleyTests/UpdateCommandTests.swift`:

```swift
import Foundation
import PiqleyCore
import Testing

@testable import piqley

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Creates a minimal .piqleyplugin zip at the given directory.
/// Returns the URL to the zip file.
private func createPluginZip(
    identifier: String,
    name: String = "Test Plugin",
    version: SemanticVersion? = SemanticVersion(major: 1, minor: 0, patch: 0),
    config: [ConfigEntry] = [],
    setup: SetupConfig? = nil,
    in directory: URL
) throws -> URL {
    let pluginDir = directory.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest = PluginManifest(
        identifier: identifier,
        name: name,
        pluginSchemaVersion: "1",
        pluginVersion: version,
        config: config,
        setup: setup
    )
    let manifestData = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
    try manifestData.write(to: pluginDir.appendingPathComponent(PluginFile.manifest))

    let zipURL = directory.appendingPathComponent("\(identifier).piqleyplugin")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", pluginDir.path, zipURL.path]
    try ditto.run()
    ditto.waitUntilExit()

    return zipURL
}

/// Installs a plugin directly by creating its directory and manifest in the plugins dir.
private func preInstallPlugin(
    identifier: String,
    name: String = "Test Plugin",
    version: SemanticVersion? = SemanticVersion(major: 1, minor: 0, patch: 0),
    config: [ConfigEntry] = [],
    setup: SetupConfig? = nil,
    in pluginsDir: URL
) throws {
    let pluginDir = pluginsDir.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest = PluginManifest(
        identifier: identifier,
        name: name,
        pluginSchemaVersion: "1",
        pluginVersion: version,
        config: config,
        setup: setup
    )
    let data = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
    try data.write(to: pluginDir.appendingPathComponent(PluginFile.manifest))
}

// MARK: - Tests

@Suite("PluginUpdater")
struct PluginUpdaterTests {

    @Test("Throws notInstalled when plugin is not installed")
    func notInstalled() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let zipDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: zipDir) }

        let zipURL = try createPluginZip(identifier: "com.test.plugin", in: zipDir)
        let pluginsDir = tempDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        #expect(throws: UpdateError.notInstalled(identifier: "com.test.plugin")) {
            try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)
        }
    }

    @Test("Throws notInstalled when zip identifier differs from installed plugin")
    func differentIdentifierThrowsNotInstalled() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginsDir = tempDir.appendingPathComponent("plugins")
        try preInstallPlugin(identifier: "com.test.old-plugin", in: pluginsDir)

        let zipDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: zipDir) }
        let zipURL = try createPluginZip(identifier: "com.test.new-plugin", in: zipDir)

        #expect(throws: UpdateError.notInstalled(identifier: "com.test.new-plugin")) {
            try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)
        }
    }

    @Test("Successful update returns old and new manifests")
    func successfulUpdate() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginsDir = tempDir.appendingPathComponent("plugins")
        try preInstallPlugin(
            identifier: "com.test.plugin",
            version: SemanticVersion(major: 1, minor: 0, patch: 0),
            config: [.value(key: "old-key", type: .string, value: .string("old"))],
            in: pluginsDir
        )

        let zipDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: zipDir) }
        let zipURL = try createPluginZip(
            identifier: "com.test.plugin",
            version: SemanticVersion(major: 2, minor: 0, patch: 0),
            config: [.value(key: "new-key", type: .string, value: .string("new"))],
            in: zipDir
        )

        let result = try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)
        #expect(result.identifier == "com.test.plugin")
        #expect(result.oldManifest.pluginVersion == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(result.newManifest.pluginVersion == SemanticVersion(major: 2, minor: 0, patch: 0))

        // New manifest is on disk
        let installedManifestURL = pluginsDir
            .appendingPathComponent("com.test.plugin")
            .appendingPathComponent(PluginFile.manifest)
        let data = try Data(contentsOf: installedManifestURL)
        let installed = try JSONDecoder.piqley.decode(PluginManifest.self, from: data)
        #expect(installed.pluginVersion == SemanticVersion(major: 2, minor: 0, patch: 0))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginUpdaterTests 2>&1`
Expected: compilation error, `UpdateError` and `PluginUpdater` do not exist.

- [ ] **Step 3: Implement UpdateError and PluginUpdater**

Create `Sources/piqley/CLI/UpdateCommand.swift`:

```swift
import ArgumentParser
import Foundation
import PiqleyCore

enum UpdateError: Error, CustomStringConvertible, Equatable {
    case fileNotFound
    case notAPiqleyPlugin
    case missingManifest
    case invalidManifest
    case unsupportedSchemaVersion
    case notInstalled(identifier: String)
    case unsupportedPlatform(host: String, supported: [String])
    case extractionFailed

    var description: String {
        switch self {
        case .fileNotFound:
            "Plugin file not found."
        case .notAPiqleyPlugin:
            "File does not have a .piqleyplugin extension."
        case .missingManifest:
            "Plugin archive does not contain a manifest.json."
        case .invalidManifest:
            "Plugin manifest is invalid."
        case .unsupportedSchemaVersion:
            "Plugin schema version is not supported."
        case let .notInstalled(identifier):
            "Plugin '\(identifier)' is not installed. Use 'piqley plugin install' instead."
        case let .unsupportedPlatform(host, supported):
            "This plugin does not support \(host). Supported platforms: \(supported.joined(separator: ", "))"
        case .extractionFailed:
            "Failed to extract plugin archive."
        }
    }
}

struct UpdateResult {
    let identifier: String
    let oldManifest: PluginManifest
    let newManifest: PluginManifest
}

enum PluginUpdater {
    @discardableResult
    static func update(from zipURL: URL, pluginsDirectory: URL) throws -> UpdateResult {
        let fileManager = FileManager.default

        // 1. Extract zip to temp dir
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("piqley-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, tempDir.path]
        try ditto.run()
        ditto.waitUntilExit()

        guard ditto.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        // 2. Find plugin directory
        let contents = try fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let pluginDir = contents.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) else {
            throw UpdateError.extractionFailed
        }

        // 3. Read and decode new manifest
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw UpdateError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let newManifest: PluginManifest
        do {
            newManifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
        } catch {
            throw UpdateError.invalidManifest
        }

        // 4. Validate schema version
        guard PluginManifest.supportedSchemaVersions.contains(newManifest.pluginSchemaVersion) else {
            throw UpdateError.unsupportedSchemaVersion
        }

        // 5. Run ManifestValidator
        let errors = ManifestValidator.validate(newManifest)
        if !errors.isEmpty {
            throw UpdateError.invalidManifest
        }

        // 6. Check platform support
        if let supportedPlatforms = newManifest.supportedPlatforms {
            guard supportedPlatforms.contains(HostPlatform.current) else {
                throw UpdateError.unsupportedPlatform(
                    host: HostPlatform.current,
                    supported: supportedPlatforms
                )
            }
        }

        // 7. Flatten platform-specific bin/ and data/ directories
        let tempBinDir = pluginDir.appendingPathComponent(PluginDirectory.bin)
        if fileManager.fileExists(atPath: tempBinDir.path) {
            let platformBinDir = tempBinDir.appendingPathComponent(HostPlatform.current)
            if fileManager.fileExists(atPath: platformBinDir.path) {
                let platformFiles = try fileManager.contentsOfDirectory(
                    at: platformBinDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )
                for file in platformFiles {
                    let dst = tempBinDir.appendingPathComponent(file.lastPathComponent)
                    try fileManager.moveItem(at: file, to: dst)
                }
                let binContents = try fileManager.contentsOfDirectory(
                    at: tempBinDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
                for item in binContents
                    where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                {
                    try fileManager.removeItem(at: item)
                }
            }
        }

        let tempDataDir = pluginDir.appendingPathComponent(PluginDirectory.data)
        if fileManager.fileExists(atPath: tempDataDir.path) {
            let platformDataDir = tempDataDir.appendingPathComponent(HostPlatform.current)
            if fileManager.fileExists(atPath: platformDataDir.path) {
                let platformFiles = try fileManager.contentsOfDirectory(
                    at: platformDataDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )
                for file in platformFiles {
                    let dst = tempDataDir.appendingPathComponent(file.lastPathComponent)
                    try fileManager.moveItem(at: file, to: dst)
                }
                let dataContents = try fileManager.contentsOfDirectory(
                    at: tempDataDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
                for item in dataContents
                    where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                {
                    try fileManager.removeItem(at: item)
                }
            }
        }

        // 8. Verify plugin is installed
        let installLocation = pluginsDirectory.appendingPathComponent(newManifest.identifier)
        guard fileManager.fileExists(atPath: installLocation.path) else {
            throw UpdateError.notInstalled(identifier: newManifest.identifier)
        }

        // 9. Read old manifest
        let oldManifestURL = installLocation.appendingPathComponent(PluginFile.manifest)
        guard fileManager.fileExists(atPath: oldManifestURL.path) else {
            throw UpdateError.missingManifest
        }
        let oldManifestData = try Data(contentsOf: oldManifestURL)
        let oldManifest: PluginManifest
        do {
            oldManifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: oldManifestData)
        } catch {
            throw UpdateError.invalidManifest
        }

        // 10. Delete old and move new
        try fileManager.removeItem(at: installLocation)
        try fileManager.moveItem(at: pluginDir, to: installLocation)

        // 11. Write installedPlatform to manifest
        let installedManifestURL = installLocation.appendingPathComponent(PluginFile.manifest)
        let rawManifestData = try Data(contentsOf: installedManifestURL)
        var manifestDict = try JSONSerialization.jsonObject(with: rawManifestData) as? [String: Any] ?? [:]
        manifestDict["installedPlatform"] = HostPlatform.current
        let updatedManifestData = try JSONSerialization.data(
            withJSONObject: manifestDict, options: [.prettyPrinted, .sortedKeys]
        )
        try updatedManifestData.write(to: installedManifestURL, options: .atomic)

        // 12. Set executable permissions on bin/ files
        let binDir = installLocation.appendingPathComponent(PluginDirectory.bin)
        if fileManager.fileExists(atPath: binDir.path) {
            let binFiles = try fileManager.contentsOfDirectory(
                at: binDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            for file in binFiles {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                process.arguments = ["+x", file.path]
                try process.run()
                process.waitUntilExit()
            }
        }

        // 13. Create logs/ and data/ directories if missing
        let logsDir = installLocation.appendingPathComponent(PluginDirectory.logs)
        if !fileManager.fileExists(atPath: logsDir.path) {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        let dataDir = installLocation.appendingPathComponent(PluginDirectory.data)
        if !fileManager.fileExists(atPath: dataDir.path) {
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }

        // 14. Return both manifests
        return UpdateResult(
            identifier: newManifest.identifier,
            oldManifest: oldManifest,
            newManifest: newManifest
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginUpdaterTests 2>&1`
Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

Commit message: `feat: add PluginUpdater with extraction, validation, and file replacement`

---

### Task 3: Add ConfigMerger and UpdateSubcommand

**Files:**
- Modify: `Sources/piqley/CLI/UpdateCommand.swift`
- Modify: `Sources/piqley/CLI/PluginCommand.swift:11-15`
- Test: `Tests/piqleyTests/UpdateCommandTests.swift`

- [ ] **Step 1: Write tests for ConfigMerger**

Add to `Tests/piqleyTests/UpdateCommandTests.swift`, after the `PluginUpdaterTests` suite:

```swift
@Suite("ConfigMerger")
struct ConfigMergerTests {

    @Test("Kept config values are preserved, new values need prompting, removed values are noted")
    func keptNewAndRemoved() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .value(key: "kept-url", type: .string, value: .string("default")),
                .value(key: "removed-key", type: .int, value: .number(42)),
            ]
        )
        let newManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .value(key: "kept-url", type: .string, value: .string("default")),
                .value(key: "new-key", type: .string, value: .null),
            ]
        )
        let existingConfig = BasePluginConfig(
            values: ["kept-url": .string("https://mysite.com"), "removed-key": .number(99)]
        )

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        // kept-url preserved
        #expect(result.mergedConfig.values["kept-url"] == .string("https://mysite.com"))
        // removed-key gone
        #expect(result.mergedConfig.values["removed-key"] == nil)
        // new-key not in merged config (scanner will prompt)
        #expect(result.mergedConfig.values["new-key"] == nil)
        // Skip sets
        #expect(result.skipValueKeys.contains("kept-url"))
        #expect(!result.skipValueKeys.contains("new-key"))
        // Removed entries
        #expect(result.removedValueKeys.contains("removed-key"))
    }

    @Test("Type change removes old value, records old and new types")
    func typeChange() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [.value(key: "port", type: .string, value: .string("8080"))]
        )
        let newManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [.value(key: "port", type: .int, value: .number(8080))]
        )
        let existingConfig = BasePluginConfig(values: ["port": .string("8080")])

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        // port should not be skipped (type changed)
        #expect(!result.skipValueKeys.contains("port"))
        // port value should be removed from merged config
        #expect(result.mergedConfig.values["port"] == nil)
        // Should record old and new types
        #expect(result.typeChangedKeys["port"] == (.string, .int))
    }

    @Test("Secret merge: kept secrets preserved, removed secrets noted")
    func secretMerge() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .secret(secretKey: "KEPT_TOKEN", type: .string),
                .secret(secretKey: "OLD_TOKEN", type: .string),
            ]
        )
        let newManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [
                .secret(secretKey: "KEPT_TOKEN", type: .string),
                .secret(secretKey: "NEW_TOKEN", type: .string),
            ]
        )
        let existingConfig = BasePluginConfig(
            secrets: ["KEPT_TOKEN": "alias-kept", "OLD_TOKEN": "alias-old"]
        )

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        #expect(result.mergedConfig.secrets["KEPT_TOKEN"] == "alias-kept")
        #expect(result.mergedConfig.secrets["OLD_TOKEN"] == nil)
        #expect(result.skipSecretKeys.contains("KEPT_TOKEN"))
        #expect(!result.skipSecretKeys.contains("NEW_TOKEN"))
        #expect(result.removedSecretKeys.contains("OLD_TOKEN"))
    }

    @Test("isSetUp is reset to nil during merge")
    func isSetUpReset() throws {
        let oldManifest = PluginManifest(
            identifier: "com.test.plugin",
            name: "Test",
            pluginSchemaVersion: "1",
            config: [.value(key: "url", type: .string, value: .string("x"))]
        )
        let newManifest = oldManifest
        let existingConfig = BasePluginConfig(
            values: ["url": .string("https://example.com")],
            isSetUp: true
        )

        let result = ConfigMerger.merge(
            oldManifest: oldManifest,
            newManifest: newManifest,
            existingConfig: existingConfig
        )

        #expect(result.mergedConfig.isSetUp == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigMergerTests 2>&1`
Expected: compilation error, `ConfigMerger` does not exist.

- [ ] **Step 3: Implement ConfigMerger**

Add to `Sources/piqley/CLI/UpdateCommand.swift`, before the `PluginUpdater` enum:

```swift
struct ConfigMergeResult {
    var mergedConfig: BasePluginConfig
    var skipValueKeys: Set<String>
    var skipSecretKeys: Set<String>
    var removedValueKeys: Set<String>
    var removedSecretKeys: Set<String>
    /// Maps key -> (oldType, newType) for entries whose type changed.
    var typeChangedKeys: [String: (ConfigValueType, ConfigValueType)]
}

enum ConfigMerger {
    static func merge(
        oldManifest: PluginManifest,
        newManifest: PluginManifest,
        existingConfig: BasePluginConfig
    ) -> ConfigMergeResult {
        // Build keyed lookups from old manifest
        var oldValueTypes: [String: ConfigValueType] = [:]
        for entry in oldManifest.config {
            if case let .value(key, type, _) = entry {
                oldValueTypes[key] = type
            }
        }
        var oldSecretTypes: [String: ConfigValueType] = [:]
        for entry in oldManifest.config {
            if case let .secret(secretKey, type) = entry {
                oldSecretTypes[secretKey] = type
            }
        }

        // Build keyed lookups from new manifest
        var newValueTypes: [String: ConfigValueType] = [:]
        for entry in newManifest.config {
            if case let .value(key, type, _) = entry {
                newValueTypes[key] = type
            }
        }
        var newSecretKeys = Set<String>()
        for entry in newManifest.config {
            if case let .secret(secretKey, _) = entry {
                newSecretKeys.insert(secretKey)
            }
        }

        var mergedConfig = existingConfig
        var skipValueKeys = Set<String>()
        var skipSecretKeys = Set<String>()
        var removedValueKeys = Set<String>()
        var removedSecretKeys = Set<String>()
        var typeChangedKeys: [String: (ConfigValueType, ConfigValueType)] = [:]

        // Process value entries in new manifest
        for (key, newType) in newValueTypes {
            if let oldType = oldValueTypes[key] {
                if oldType == newType, mergedConfig.values[key] != nil {
                    // Same type, carry over
                    skipValueKeys.insert(key)
                } else if oldType != newType {
                    // Type changed: remove old value, will be re-prompted
                    mergedConfig.values.removeValue(forKey: key)
                    typeChangedKeys[key] = (oldType, newType)
                }
            }
            // New keys: nothing to do, scanner will prompt
        }

        // Process secret entries in new manifest
        for secretKey in newSecretKeys {
            if oldSecretTypes[secretKey] != nil, mergedConfig.secrets[secretKey] != nil {
                skipSecretKeys.insert(secretKey)
            }
        }

        // Find removed value keys
        for key in oldValueTypes.keys where newValueTypes[key] == nil {
            mergedConfig.values.removeValue(forKey: key)
            removedValueKeys.insert(key)
        }

        // Find removed secret keys
        for key in oldSecretTypes.keys where !newSecretKeys.contains(key) {
            mergedConfig.secrets.removeValue(forKey: key)
            removedSecretKeys.insert(key)
        }

        // Reset isSetUp so setup binary re-runs
        mergedConfig.isSetUp = nil

        return ConfigMergeResult(
            mergedConfig: mergedConfig,
            skipValueKeys: skipValueKeys,
            skipSecretKeys: skipSecretKeys,
            removedValueKeys: removedValueKeys,
            removedSecretKeys: removedSecretKeys,
            typeChangedKeys: typeChangedKeys
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigMergerTests 2>&1`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

Commit message: `feat: add ConfigMerger for update command config/secret diffing`

- [ ] **Step 6: Implement UpdateSubcommand**

Add to the bottom of `Sources/piqley/CLI/UpdateCommand.swift`:

```swift
struct UpdateSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an installed plugin from a .piqleyplugin package"
    )

    @Argument(help: "Path to the .piqleyplugin file")
    var pluginFile: String

    func validate() throws {
        guard FileManager.default.fileExists(atPath: pluginFile) else {
            throw UpdateError.fileNotFound
        }
        guard pluginFile.hasSuffix(".piqleyplugin") else {
            throw UpdateError.notAPiqleyPlugin
        }
    }

    func run() throws {
        let zipURL = URL(fileURLWithPath: pluginFile)
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

        let result = try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)

        // Print version transition
        if let oldVersion = result.oldManifest.pluginVersion,
           let newVersion = result.newManifest.pluginVersion
        {
            print("Updating \(result.identifier) from \(oldVersion) to \(newVersion)")
        }
        print("Plugin files updated successfully.")

        // Load existing config
        let configStore = BasePluginConfigStore.default
        let existingConfig = (try? configStore.load(for: result.identifier)) ?? BasePluginConfig()

        // Merge configs
        let mergeResult = ConfigMerger.merge(
            oldManifest: result.oldManifest,
            newManifest: result.newManifest,
            existingConfig: existingConfig
        )

        // Print kept entries
        for key in mergeResult.skipValueKeys.sorted() {
            if let value = mergeResult.mergedConfig.values[key] {
                print("Kept config '\(key)' = \(value)")
            }
        }
        for key in mergeResult.skipSecretKeys.sorted() {
            print("Kept secret '\(key)'")
        }

        // Print removed entries
        for key in mergeResult.removedValueKeys.sorted() {
            print("Removed config '\(key)' (no longer in manifest).")
        }
        for key in mergeResult.removedSecretKeys.sorted() {
            print("Removed secret '\(key)' (no longer in manifest).")
        }

        // Print type changes
        for (key, (oldType, newType)) in mergeResult.typeChangedKeys.sorted(by: { $0.key < $1.key }) {
            print("Config '\(key)' type changed from \(oldType.rawValue) to \(newType.rawValue), re-prompting.")
        }

        // Save merged config before scan so scanner picks it up
        try configStore.save(mergeResult.mergedConfig, for: result.identifier)

        // Run scanner for new/changed entries + setup binary
        guard !result.newManifest.config.isEmpty || result.newManifest.setup != nil else {
            // Prune orphaned secrets
            let secretStore = makeDefaultSecretStore()
            let pruned = try SecretPruner.prune(configStore: configStore, secretStore: secretStore)
            if !pruned.isEmpty {
                print("Pruned \(pruned.count) orphaned secret(s).")
            }
            print("\nUpdate complete.")
            return
        }

        let (_, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()
        guard let plugin = allPlugins.first(where: { $0.identifier == result.identifier }) else {
            print("\nUpdate complete.")
            return
        }

        print("\nRunning setup for '\(plugin.name)'...\n")
        let secretStore = makeDefaultSecretStore()
        var scanner = PluginSetupScanner(
            secretStore: secretStore,
            configStore: configStore,
            inputSource: StdinInputSource()
        )
        try scanner.scan(
            plugin: plugin,
            skipValueKeys: mergeResult.skipValueKeys,
            skipSecretKeys: mergeResult.skipSecretKeys
        )

        // Prune orphaned secrets
        let pruned = try SecretPruner.prune(configStore: configStore, secretStore: secretStore)
        if !pruned.isEmpty {
            print("Pruned \(pruned.count) orphaned secret(s).")
        }

        print("\nUpdate complete.")
    }
}
```

- [ ] **Step 7: Register UpdateSubcommand in PluginCommand**

In `Sources/piqley/CLI/PluginCommand.swift`, add `UpdateSubcommand.self` to the `subcommands` array. Change:

```swift
        subcommands: [
            ListSubcommand.self, SetupSubcommand.self, InitSubcommand.self,
            CreateSubcommand.self, InstallSubcommand.self, UninstallSubcommand.self,
            ConfigSubcommand.self, PluginRulesCommand.self, PluginCommandEditCommand.self,
        ]
```

to:

```swift
        subcommands: [
            ListSubcommand.self, SetupSubcommand.self, InitSubcommand.self,
            CreateSubcommand.self, InstallSubcommand.self, UpdateSubcommand.self,
            UninstallSubcommand.self,
            ConfigSubcommand.self, PluginRulesCommand.self, PluginCommandEditCommand.self,
        ]
```

- [ ] **Step 8: Verify all tests pass**

Run: `swift test 2>&1`
Expected: all tests pass, including the new PluginUpdaterTests and ConfigMergerTests, and all existing tests remain green.

- [ ] **Step 9: Commit**

Commit message: `feat: add piqley plugin update command with config merging`

---

### Task 4: Update documentation

**Files:**
- Modify: `docs/getting-started.md` (if it documents plugin commands)
- Modify: `docs/advanced-topics.md` (if it documents plugin management)

- [ ] **Step 1: Check if docs mention plugin install**

Read `docs/getting-started.md` and `docs/advanced-topics.md` to see if they document plugin commands. If they do, add a section about `plugin update` next to the existing `plugin install` docs.

- [ ] **Step 2: Add update command documentation**

Add a brief section documenting the update command near the existing install documentation. Cover: command syntax, what it does, how config merging works (kept/new/removed/type-changed).

- [ ] **Step 3: Commit**

Commit message: `docs: add plugin update command to documentation`
