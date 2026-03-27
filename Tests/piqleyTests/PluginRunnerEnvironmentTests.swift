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

private func makePluginWithEnvironment(
    name: String,
    hook: String,
    scriptURL: URL,
    environment: [String: String],
    args: [String] = [],
    protocol proto: String = "pipe",
    batchProxy: Bool = false
) throws -> LoadedPlugin {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let manifestJSON: [String: Any] = [
        "identifier": name,
        "name": name,
        "type": "static",
        "pluginSchemaVersion": "1"
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestJSON)
    try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

    var binaryDict: [String: Any] = [
        "command": scriptURL.path,
        "args": args,
        "protocol": proto,
        "environment": environment
    ]
    if batchProxy {
        binaryDict["batchProxy"] = ["sort": ["key": "filename", "order": "ascending"]] as [String: Any]
    }
    let stageJSON: [String: Any] = ["binary": binaryDict]
    let stageData = try JSONSerialization.data(withJSONObject: stageJSON)
    try stageData.write(to: tempDir.appendingPathComponent("stage-\(hook).json"))

    try FileManager.default.createDirectory(
        at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true
    )
    let decoded = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
    let knownHooks = Set(StandardHook.canonicalOrder.map(\.rawValue))
    let (stages, _) = PluginDiscovery.loadStages(from: tempDir, knownHooks: knownHooks)
    return LoadedPlugin(
        identifier: decoded.identifier, name: name, directory: tempDir,
        manifest: decoded, stages: stages
    )
}

@Suite("PluginRunner Environment Mapping")
struct PluginRunnerEnvironmentTests {
    let tempFolder: TempFolder

    init() throws {
        tempFolder = try TempFolder.create()
        let imgPath = tempFolder.url.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath)
    }

    // MARK: - resolveTemplate unit tests

    @Test("resolves simple field reference")
    func testResolveSimpleField() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "test", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:CameraMake": .string("Canon")]
        ]
        let result = await runner.resolveTemplate("{{original:EXIF:CameraMake}}", imageState: state, imageName: nil)
        #expect(result == "Canon")
    }

    @Test("resolves self namespace to plugin identifier")
    func testResolveSelfNamespace() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "com.test.myplugin", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "com.test.myplugin": ["tags": .array([.string("landscape"), .string("sunset")])]
        ]
        let result = await runner.resolveTemplate("{{self:tags}}", imageState: state, imageName: nil)
        #expect(result == "landscape,sunset")
    }

    @Test("resolves multiple templates in one string")
    func testResolveMultipleTemplates() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "test", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "original": [
                "EXIF:CameraMake": .string("Canon"),
                "EXIF:LensModel": .string("RF 24-70mm")
            ]
        ]
        let result = await runner.resolveTemplate(
            "{{original:EXIF:CameraMake}} with {{original:EXIF:LensModel}}",
            imageState: state, imageName: nil
        )
        #expect(result == "Canon with RF 24-70mm")
    }

    @Test("missing field resolves to empty string")
    func testMissingFieldResolvesToEmpty() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "test", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let result = await runner.resolveTemplate("{{original:EXIF:Missing}}", imageState: [:], imageName: nil)
        #expect(result == "")
    }

    @Test("literal string without templates passes through unchanged")
    func testLiteralPassthrough() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "test", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let result = await runner.resolveTemplate("https://example.com", imageState: nil, imageName: nil)
        #expect(result == "https://example.com")
    }

    @Test("number values resolve correctly")
    func testNumberResolution() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "test", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:FocalLength": .number(50)]
        ]
        let result = await runner.resolveTemplate("{{original:EXIF:FocalLength}}", imageState: state, imageName: nil)
        #expect(result == "50")
    }

    @Test("bool values resolve correctly")
    func testBoolResolution() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "test", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:Flash": .bool(true)]
        ]
        let result = await runner.resolveTemplate("{{original:EXIF:Flash}}", imageState: state, imageName: nil)
        #expect(result == "true")
    }

    @Test("bare colon-delimited field falls back to plugin namespace")
    func testBareFieldFallsBackToPluginNamespace() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "com.test.myplugin", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "com.test.myplugin": ["IPTC:Keywords": .array([.string("landscape"), .string("sunset")])]
        ]
        let result = await runner.resolveTemplate("{{IPTC:Keywords}}", imageState: state, imageName: nil)
        #expect(result == "landscape,sunset")
    }

    @Test("bare field fallback does not shadow a real namespace match")
    func testBareFieldDoesNotShadowRealNamespace() async throws {
        let script = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePluginWithEnvironment(
            name: "com.test.myplugin", hook: "publish", scriptURL: script, environment: [:]
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:CameraMake": .string("Canon")]
        ]
        let result = await runner.resolveTemplate("{{original:EXIF:CameraMake}}", imageState: state, imageName: nil)
        #expect(result == "Canon")
    }

    // MARK: - Integration: environment vars available to subprocess

    @Test("environment mapping makes resolved vars available to pipe subprocess")
    func testEnvMappingInPipeSubprocess() async throws {
        let resultFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-env-test-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        echo "$CAMERA|$TAGS|$LITERAL" > "\(resultFile.path)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: resultFile)
        }

        let plugin = try makePluginWithEnvironment(
            name: "com.test.env", hook: "post-publish", scriptURL: script,
            environment: [
                "CAMERA": "{{original:EXIF:CameraMake}}",
                "TAGS": "{{self:tags}}",
                "LITERAL": "hello"
            ],
            protocol: "pipe"
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let state: [String: [String: [String: JSONValue]]] = [
            "test.jpg": [
                "original": ["EXIF:CameraMake": .string("Nikon")],
                "com.test.env": ["tags": .array([.string("portrait"), .string("studio")])]
            ]
        ]
        let hookConfig = plugin.stages["post-publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let (result, _) = try await runner.run(
            hook: "post-publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false,
            state: state
        )
        #expect(result == .success)

        let output = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "Nikon|portrait,studio|hello")
    }

    @Test("environment mapping vars are substituted in args")
    func testEnvMappingSubstitutedInArgs() async throws {
        let resultFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-args-test-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        echo "$1|$2" > "\(resultFile.path)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: resultFile)
        }

        let plugin = try makePluginWithEnvironment(
            name: "com.test.args", hook: "post-publish", scriptURL: script,
            environment: [
                "CAMERA": "{{original:EXIF:CameraMake}}"
            ],
            args: ["$CAMERA", "literal-arg"],
            protocol: "pipe"
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let state: [String: [String: [String: JSONValue]]] = [
            "test.jpg": [
                "original": ["EXIF:CameraMake": .string("Sony")]
            ]
        ]
        let hookConfig = plugin.stages["post-publish"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let (result, _) = try await runner.run(
            hook: "post-publish",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false,
            state: state
        )
        #expect(result == .success)

        let output = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "Sony|literal-arg")
    }

    @Test("batchProxy resolves environment per image")
    func testBatchProxyPerImageEnv() async throws {
        let callLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-batch-env-\(UUID().uuidString).txt")
        let script = try makeTempScript("""
        echo "$CAMERA" >> "\(callLog.path)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: callLog)
        }

        // Add a second image to the temp folder
        let img2Path = tempFolder.url.appendingPathComponent("photo2.jpg").path
        try TestFixtures.createTestJPEG(at: img2Path)

        let plugin = try makePluginWithEnvironment(
            name: "com.test.batch", hook: "pre-process", scriptURL: script,
            environment: ["CAMERA": "{{original:EXIF:CameraMake}}"],
            protocol: "pipe", batchProxy: true
        )
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let state: [String: [String: [String: JSONValue]]] = [
            "photo2.jpg": ["original": ["EXIF:CameraMake": .string("Canon")]],
            "test.jpg": ["original": ["EXIF:CameraMake": .string("Nikon")]]
        ]
        let hookConfig = plugin.stages["pre-process"]?.binary
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let (result, _) = try await runner.run(
            hook: "pre-process",
            hookConfig: hookConfig,
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            debug: false,
            state: state
        )
        #expect(result == .success)

        let calls = (try? String(contentsOf: callLog, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(calls.count == 2)
        // batchProxy sorts by filename ascending: photo2.jpg then test.jpg
        #expect(calls[0] == "Canon")
        #expect(calls[1] == "Nikon")
    }
}
