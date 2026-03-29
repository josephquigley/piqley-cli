import Testing
import Foundation
import PiqleyCore
@testable import piqley

private func makeTempScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-plugin-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func makePlugin(name: String, hook: String, scriptURL: URL) throws -> LoadedPlugin {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    // Write manifest (no hooks — stage-based now)
    let manifestJSON: [String: Any] = [
        "identifier": name,
        "name": name,
        "pluginSchemaVersion": "1"
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestJSON)
    try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

    // Write stage file
    let stageJSON: [String: Any] = [
        "binary": ["command": scriptURL.path, "args": [], "protocol": "json"]
    ]
    let stageData = try JSONSerialization.data(withJSONObject: stageJSON)
    try stageData.write(to: tempDir.appendingPathComponent("stage-\(hook).json"))

    try FileManager.default.createDirectory(
        at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true
    )
    let decoded = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
    let knownHooks = Set(StandardHook.canonicalOrder.map(\.rawValue))
    let (stages, _) = PluginDiscovery.loadStages(from: tempDir, knownHooks: knownHooks)
    return LoadedPlugin(identifier: decoded.identifier, name: name, directory: tempDir, manifest: decoded, stages: stages)
}

@Suite("PluginRunner State")
struct PluginRunnerStateTests {
    let tempFolder: TempFolder

    init() throws {
        tempFolder = try TempFolder.create()
        let imgPath = tempFolder.url.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath)
    }

    @Test("state is included in JSON payload when provided")
    func testStateInPayload() async throws {
        // Script reads stdin JSON payload via python and checks for state field
        let script = try makeTempScript("""
        INPUT=$(cat)
        HAS_STATE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'state' in d else 'no')")
        if [ "$HAS_STATE" = "yes" ]; then
            printf '{"type":"result","success":true,"error":null}\\n'
        else
            printf '{"type":"result","success":false,"error":"no state in payload"}\\n'
            exit 1
        fi
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let state: [String: [String: [String: JSONValue]]] = [
            "test.jpg": ["original": ["IPTC:Keywords": .array([.string("cat")])]],
        ]
        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            state: state
        )
        #expect(output.exitResult == .success)
    }

    @Test("state is captured from plugin result response")
    func testStateCaptured() async throws {
        let script = try makeTempScript("""
        cat > /dev/null
        printf '{"type":"result","success":true,"state":{"test.jpg":{"hashtags":["#cat","#dog"]}}}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "hashtag", hook: "post-process", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["post-process"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "post-process",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            state: nil
        )
        #expect(output.exitResult == .success)
        #expect(output.state?["test.jpg"]?["hashtags"] == .array([.string("#cat"), .string("#dog")]))
    }

    @Test("no state in response returns nil")
    func testNoStateReturned() async throws {
        let script = try makeTempScript("""
        cat > /dev/null
        printf '{"type":"result","success":true}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            state: nil
        )
        #expect(output.exitResult == .success)
        #expect(output.state == nil)
    }
}
