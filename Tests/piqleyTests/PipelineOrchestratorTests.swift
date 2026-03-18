import Testing
import Foundation
@testable import piqley

/// A fake SecretStore that returns pre-configured values, throws for missing keys.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]

    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }
    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
}

private func makePluginsDir(withPlugin name: String, hook: String, scriptURL: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
    let pluginDir = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
        "name": name,
        "pluginProtocolVersion": "1",
        "hooks": [hook: ["command": scriptURL.path, "args": [], "protocol": "pipe"]]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try data.write(to: pluginDir.appendingPathComponent("manifest.json"))
    return dir
}

private func makeSourceDir(withImage: Bool = true) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-src-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if withImage {
        try TestFixtures.createTestJPEG(at: dir.appendingPathComponent("photo.jpg").path)
    }
    return dir
}

private func makeTempScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-script-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite("PipelineOrchestrator")
struct PipelineOrchestratorTests {
    @Test("successful pipeline returns true")
    func testSuccess() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(withPlugin: "test-plugin", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var config = AppConfig()
        config.pipeline["publish"] = ["test-plugin"]
        config.autoDiscoverPlugins = false

        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore()
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == true)
    }

    @Test("critical plugin failure returns false and aborts pipeline")
    func testCriticalAborts() async throws {
        let failScript = try makeTempScript("exit 1")
        let successScript = try makeTempScript("exit 0")
        defer {
            try? FileManager.default.removeItem(at: failScript)
            try? FileManager.default.removeItem(at: successScript)
        }

        // Two plugins in publish hook: first fails critically, second should never run
        let pluginsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-orch-\(UUID().uuidString)")

        for (name, script) in [("fail-plugin", failScript), ("ok-plugin", successScript)] {
            let pluginDir = pluginsDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "name": name,
                "pluginProtocolVersion": "1",
                "hooks": ["publish": ["command": script.path, "args": [], "protocol": "pipe"]]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: pluginDir.appendingPathComponent("manifest.json"))
        }
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var config = AppConfig()
        config.pipeline["publish"] = ["fail-plugin", "ok-plugin"]
        config.autoDiscoverPlugins = false

        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore()
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == false)
    }

    @Test("missing required secret is a critical failure")
    func testMissingSecretIsCritical() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let pluginsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
        let pluginDir = pluginsDir.appendingPathComponent("secret-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "secret-plugin",
            "pluginProtocolVersion": "1",
            "config": [["secret_key": "api-key", "type": "string"]],
            "hooks": ["publish": ["command": script.path, "args": [], "protocol": "pipe"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: pluginDir.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var config = AppConfig()
        config.pipeline["publish"] = ["secret-plugin"]
        config.autoDiscoverPlugins = false

        let orchestrator = PipelineOrchestrator(
            config: config,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore() // no secrets configured
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == false)
    }
}
