import Testing
import Foundation
import PiqleyCore
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

private func makePluginsDir(withPlugin identifier: String, hook: String, scriptURL: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
    let pluginDir = dir.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    // Write manifest with identifier (no hooks)
    let manifest: [String: Any] = [
        "identifier": identifier,
        "name": identifier,
        "pluginSchemaVersion": "1"
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest)
    try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))
    // Write stage file for the hook
    let stageConfig: [String: Any] = [
        "binary": ["command": scriptURL.path, "args": [], "protocol": "pipe"]
    ]
    let stageData = try JSONSerialization.data(withJSONObject: stageConfig)
    try stageData.write(to: pluginDir.appendingPathComponent("stage-\(hook).json"))
    try FileManager.default.createDirectory(at: pluginDir.appendingPathComponent("data"), withIntermediateDirectories: true)
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

private func makePluginsDirWithSkipRule(identifier: String, hook: String, scriptURL: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-orch-\(UUID().uuidString)")
    let pluginDir = dir.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
        "identifier": identifier,
        "name": identifier,
        "pluginSchemaVersion": "1"
    ]
    try JSONSerialization.data(withJSONObject: manifest)
        .write(to: pluginDir.appendingPathComponent("manifest.json"))

    let skipEmit: [String: Any] = ["action": "skip"]
    let matchConfig: [String: Any] = ["field": "original:IPTC:Keywords", "pattern": "glob:*Draft*"]
    let stageConfig: [String: Any] = [
        "preRules": [["match": matchConfig, "emit": [skipEmit]]],
        "binary": ["command": scriptURL.path, "args": [], "protocol": "pipe"]
    ]
    try JSONSerialization.data(withJSONObject: stageConfig)
        .write(to: pluginDir.appendingPathComponent("stage-\(hook).json"))

    try FileManager.default.createDirectory(
        at: pluginDir.appendingPathComponent("data"), withIntermediateDirectories: true
    )
    return dir
}

@Suite("PipelineOrchestrator")
struct PipelineOrchestratorTests {
    @Test("successful pipeline returns true")
    func testSuccess() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(withPlugin: "com.test.test-plugin", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test")
        workflow.pipeline["publish"] = ["com.test.test-plugin"]

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
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

        for (identifier, script) in [("com.test.fail-plugin", failScript), ("com.test.ok-plugin", successScript)] {
            let pluginDir = pluginsDir.appendingPathComponent(identifier)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "identifier": identifier,
                "name": identifier,
                "pluginSchemaVersion": "1"
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))
            let stageConfig: [String: Any] = [
                "binary": ["command": script.path, "args": [], "protocol": "pipe"]
            ]
            let stageData = try JSONSerialization.data(withJSONObject: stageConfig)
            try stageData.write(to: pluginDir.appendingPathComponent("stage-publish.json"))
            try FileManager.default.createDirectory(at: pluginDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test")
        workflow.pipeline["publish"] = ["com.test.fail-plugin", "com.test.ok-plugin"]

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
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
        let pluginDir = pluginsDir.appendingPathComponent("com.test.secret-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "identifier": "com.test.secret-plugin",
            "name": "secret-plugin",
            "pluginSchemaVersion": "1",
            "config": [["secret_key": "api-key", "type": "string"]]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))
        let stageConfig: [String: Any] = [
            "binary": ["command": script.path, "args": [], "protocol": "pipe"]
        ]
        let stageData = try JSONSerialization.data(withJSONObject: stageConfig)
        try stageData.write(to: pluginDir.appendingPathComponent("stage-publish.json"))
        try FileManager.default.createDirectory(at: pluginDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test")
        workflow.pipeline["publish"] = ["com.test.secret-plugin"]

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore() // no secrets configured
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == false)
    }

    @Test("skip rule prevents binary execution for matched image")
    func skipRulePreventsBinary() async throws {
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-skip-marker-\(UUID().uuidString)")
        let script = try makeTempScript("touch \"\(markerPath.path)\"")
        defer { try? FileManager.default.removeItem(at: script) }

        let pluginsDir = try makePluginsDirWithSkipRule(
            identifier: "com.test.skip-plugin", hook: "pre-process", scriptURL: script
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir(withImage: false)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        try TestFixtures.createTestJPEG(
            at: sourceDir.appendingPathComponent("photo.jpg").path,
            keywords: ["Draft-Photo"]
        )

        var workflow = Workflow.empty(name: "test")
        workflow.pipeline["pre-process"] = ["com.test.skip-plugin"]

        let orchestrator = PipelineOrchestrator(
            workflow: workflow, pluginsDirectory: pluginsDir, secretStore: FakeSecretStore()
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false)
        #expect(result == true)
        #expect(!FileManager.default.fileExists(atPath: markerPath.path))
    }
}
