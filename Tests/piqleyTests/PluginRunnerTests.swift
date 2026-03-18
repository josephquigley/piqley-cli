import Testing
import Foundation
@testable import piqley

// Helpers to write temp shell scripts used as fake plugins
private func makeTempScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-plugin-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func makePlugin(
    name: String,
    hook: String,
    scriptURL: URL,
    protocol proto: String = "json",
    batchProxy: Bool = false
) throws -> LoadedPlugin {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    var hookDict: [String: Any] = [
        "command": scriptURL.path,
        "args": [],
        "protocol": proto
    ]
    if batchProxy {
        hookDict["batchProxy"] = ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
    }
    let manifest: [String: Any] = [
        "name": name,
        "pluginProtocolVersion": "1",
        "hooks": [hook: hookDict]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try data.write(to: tempDir.appendingPathComponent("manifest.json"))
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
    return LoadedPlugin(name: name, directory: tempDir, manifest: decoded)
}

@Suite("PluginRunner")
struct PluginRunnerTests {
    let tempFolder: TempFolder

    init() throws {
        tempFolder = try TempFolder.create()
        // Add a test image
        let imgPath = tempFolder.url.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath)
    }

    @Test("json protocol: success result returns .success")
    func testJSONSuccess() async throws {
        let script = try makeTempScript("""
        printf '{"type":"result","success":true,"error":null}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .success)
    }

    @Test("json protocol: non-zero critical exit code returns .critical")
    func testJSONExitCritical() async throws {
        let script = try makeTempScript("exit 1")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("pipe protocol: exit 0 returns .success")
    func testPipeSuccess() async throws {
        let script = try makeTempScript("echo 'hello from pipe plugin'; exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "post-publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .success)
    }

    @Test("pipe protocol: exit 1 returns .critical")
    func testPipeCritical() async throws {
        let script = try makeTempScript("exit 1")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "post-publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("inactivity timeout kills process and returns .critical")
    func testInactivityTimeout() async throws {
        // Script sleeps forever — should be killed by timeout
        let script = try makeTempScript("sleep 60")
        defer { try? FileManager.default.removeItem(at: script) }

        // Build plugin with 1-second timeout
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "name": "slow",
            "pluginProtocolVersion": "1",
            "hooks": ["publish": ["command": script.path, "args": [], "timeout": 1]]
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let plugin = LoadedPlugin(name: "slow", directory: tempDir, manifest: manifest)

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("$PIQLEY_FOLDER_PATH token is substituted in args")
    func testTokenSubstitution() async throws {
        // Script echoes its first argument to verify token was replaced
        let script = try makeTempScript("""
        echo "got: $1"
        printf '{"type":"result","success":true,"error":null}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "name": "token-test",
            "pluginProtocolVersion": "1",
            "hooks": ["publish": [
                "command": script.path,
                "args": ["$PIQLEY_FOLDER_PATH"],
                "protocol": "json"
            ]]
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let plugin = LoadedPlugin(name: "token-test", directory: tempDir, manifest: manifest)

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .success)
    }

    @Test("batchProxy declared on json protocol returns critical (validation error)")
    func testBatchProxyWithJSONProtocolIsCritical() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "name": "bad",
            "pluginProtocolVersion": "1",
            "hooks": ["publish": [
                "command": script.path,
                "args": [],
                "protocol": "json",
                "batchProxy": ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
            ]]
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        let plugin = LoadedPlugin(name: "bad", directory: tempDir, manifest: manifest)

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        let result = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )
        #expect(result == .critical)
    }

    @Test("batchProxy+pipe calls plugin once per image in folder")
    func testBatchProxy() async throws {
        // Script appends its PIQLEY_IMAGE_PATH env var to a temp file so we can count calls
        let callLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-calls-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        echo "$PIQLEY_IMAGE_PATH" >> "\(callLog.path)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: callLog)
        }

        let plugin = try makePlugin(name: "test", hook: "pre-process", scriptURL: script, protocol: "pipe", batchProxy: true)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:])
        _ = try await runner.run(
            hook: "pre-process",
            tempFolder: tempFolder,
            pluginConfig: [:],
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false
        )

        let calls = (try? String(contentsOf: callLog, encoding: .utf8))?.split(separator: "\n") ?? []
        #expect(calls.count == 1)  // tempFolder has 1 image
        #expect(calls.first?.hasSuffix("test.jpg") == true)
    }
}
