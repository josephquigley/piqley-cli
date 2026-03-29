import Testing
import Foundation
import PiqleyCore
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

    // Write manifest (no hooks — stage-based now)
    let manifestJSON: [String: Any] = [
        "identifier": name,
        "name": name,
        "type": "static",
        "pluginSchemaVersion": "1"
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestJSON)
    try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

    // Build stage binary config
    var binaryDict: [String: Any] = [
        "command": scriptURL.path,
        "args": [],
        "protocol": proto
    ]
    if batchProxy {
        binaryDict["batchProxy"] = ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
    }
    let stageJSON: [String: Any] = ["binary": binaryDict]
    let stageData = try JSONSerialization.data(withJSONObject: stageJSON)
    try stageData.write(to: tempDir.appendingPathComponent("stage-\(hook).json"))

    try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true)
    let decoded = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
    let knownHooks = Set(StandardHook.canonicalOrder.map(\.rawValue))
    let (stages, _) = PluginDiscovery.loadStages(from: tempDir, knownHooks: knownHooks)
    return LoadedPlugin(identifier: decoded.identifier, name: name, directory: tempDir, manifest: decoded, stages: stages)
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

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .success)
    }

    @Test("json protocol: error message is captured from result line")
    func testJSONErrorMessage() async throws {
        let script = try makeTempScript("""
        printf '{"type":"result","success":false,"error":"Ghost API returned 401 Unauthorized"}\\n'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .critical)
        #expect(output.errorMessage == "Ghost API returned 401 Unauthorized")
    }

    @Test("json protocol: success result has nil error message")
    func testJSONSuccessNoError() async throws {
        let script = try makeTempScript("""
        printf '{"type":"result","success":true,"error":null}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .success)
        #expect(output.errorMessage == nil)
    }

    @Test("json protocol: non-zero critical exit code returns .critical")
    func testJSONExitCritical() async throws {
        let script = try makeTempScript("exit 1")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .critical)
    }

    @Test("pipe protocol: exit 0 returns .success")
    func testPipeSuccess() async throws {
        let script = try makeTempScript("echo 'hello from pipe plugin'; exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["post-publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "post-publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .success)
    }

    @Test("pipe protocol: exit 1 returns .critical")
    func testPipeCritical() async throws {
        let script = try makeTempScript("exit 1")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["post-publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "post-publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .critical)
    }

    @Test("inactivity timeout kills process and returns .critical")
    func testInactivityTimeout() async throws {
        // Script sleeps forever — should be killed by timeout
        let script = try makeTempScript("sleep 60")
        defer { try? FileManager.default.removeItem(at: script) }

        // Build plugin with 1-second timeout using a stage file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "identifier": "slow",
            "name": "slow",
            "type": "static",
            "pluginSchemaVersion": "1"
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

        let stageData = try JSONSerialization.data(withJSONObject: [
            "binary": ["command": script.path, "args": [], "timeout": 1]
        ] as [String: Any])
        try stageData.write(to: tempDir.appendingPathComponent("stage-publish.json"))

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
        let knownHooks = Set(StandardHook.canonicalOrder.map(\.rawValue))
        let (stages, _) = PluginDiscovery.loadStages(from: tempDir, knownHooks: knownHooks)
        let plugin = LoadedPlugin(identifier: "slow", name: "slow", directory: tempDir, manifest: manifest, stages: stages)

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .critical)
    }

    @Test("$PIQLEY_IMAGE_FOLDER_PATH token is substituted in args")
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
            "identifier": "token-test",
            "name": "token-test",
            "type": "static",
            "pluginSchemaVersion": "1"
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

        let stageData = try JSONSerialization.data(withJSONObject: [
            "binary": [
                "command": script.path,
                "args": ["$PIQLEY_IMAGE_FOLDER_PATH"],
                "protocol": "json"
            ]
        ] as [String: Any])
        try stageData.write(to: tempDir.appendingPathComponent("stage-publish.json"))

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
        let knownHooks = Set(StandardHook.canonicalOrder.map(\.rawValue))
        let (stages, _) = PluginDiscovery.loadStages(from: tempDir, knownHooks: knownHooks)
        let plugin = LoadedPlugin(identifier: "token-test", name: "token-test", directory: tempDir, manifest: manifest, stages: stages)

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .success)
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
            "identifier": "bad",
            "name": "bad",
            "type": "static",
            "pluginSchemaVersion": "1"
        ] as [String: Any])
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

        // batchProxy+json is invalid — PluginDiscovery.loadStages skips it
        // So the stage will be nil, and the runner should return .critical
        let stageData = try JSONSerialization.data(withJSONObject: [
            "binary": [
                "command": script.path,
                "args": [],
                "protocol": "json",
                "batchProxy": ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
            ]
        ] as [String: Any])
        try stageData.write(to: tempDir.appendingPathComponent("stage-publish.json"))

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
        let knownHooks = Set(StandardHook.canonicalOrder.map(\.rawValue))
        let (stages, _) = PluginDiscovery.loadStages(from: tempDir, knownHooks: knownHooks)
        let plugin = LoadedPlugin(identifier: "bad", name: "bad", directory: tempDir, manifest: manifest, stages: stages)

        // Stage was skipped by loadStages — hookConfig will be nil → runner returns .critical
        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .critical)
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

        let hookConfig = plugin.stages["pre-process"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        _ = try await runner.run(
            hook: "pre-process",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )

        let calls = (try? String(contentsOf: callLog, encoding: .utf8))?.split(separator: "\n") ?? []
        #expect(calls.count == 1)  // tempFolder has 1 image
        #expect(calls.first?.hasSuffix("test.jpg") == true)
    }

    @Test("PIQLEY_CONFIG_* env vars are set from pluginConfig values")
    func testPluginConfigEnvVars() async throws {
        // Script checks for PIQLEY_CONFIG_API_URL and PIQLEY_CONFIG_RETRY_COUNT env vars,
        // outputs a result line only if they match expected values
        let script = try makeTempScript("""
        if [ "$PIQLEY_CONFIG_API_URL" = "https://example.com" ] && [ "$PIQLEY_CONFIG_RETRY_COUNT" = "3" ]; then
            printf '{"type":"result","success":true,"error":null}\\n'
            exit 0
        else
            printf '{"type":"result","success":false,"error":"env vars not set correctly"}\\n'
            exit 1
        fi
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let config = PluginConfig(values: [
            "api-url": .string("https://example.com"),
            "retry-count": .number(3)
        ])
        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: config)
        let output = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false
        )
        #expect(output.exitResult == .success)
    }

    @Test("pipe protocol: PIQLEY_DEBUG env var is set when debug=true")
    func testPipeDebugEnvVar() async throws {
        let resultFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-debug-test-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        echo "$PIQLEY_DEBUG" > "\(resultFile.path)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: resultFile)
        }

        let plugin = try makePlugin(name: "test", hook: "post-publish", scriptURL: script, protocol: "pipe")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["post-publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let runOutput = try await runner.run(
            hook: "post-publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: true
        )
        #expect(runOutput.exitResult == .success)

        let fileContents = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fileContents == "1")
    }

    @Test("json protocol: debug field is included in JSON payload")
    func testJSONDebugField() async throws {
        // Script reads stdin JSON and checks for debug field
        let resultFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-json-debug-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        input=$(cat)
        debug=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('debug', 'missing'))")
        echo "$debug" > "\(resultFile.path)"
        printf '{"type":"result","success":true,"error":null}\\n'
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: resultFile)
        }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script, protocol: "json")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let hookConfig = plugin.stages["publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let runOutput = try await runner.run(
            hook: "publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: true
        )
        #expect(runOutput.exitResult == .success)

        let fileContents = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fileContents == "True")
    }
}
