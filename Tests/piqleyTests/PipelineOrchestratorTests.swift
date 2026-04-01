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
    func list() throws -> [String] { Array(secrets.keys) }
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
        "type": "static",
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

/// Create a workflows root directory with rules for plugins.
/// Copies stage files from the plugin directory into the workflow rules structure.
private func makeWorkflowsRoot(
    workflowName: String,
    pluginsDir: URL,
    identifiers: [String]
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-wf-root-\(UUID().uuidString)")
    for identifier in identifiers {
        let pluginDir = pluginsDir.appendingPathComponent(identifier)
        try WorkflowStore.seedRules(
            workflowName: workflowName,
            pluginIdentifier: identifier,
            pluginDirectory: pluginDir,
            root: root
        )
    }
    return root
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
        "type": "static",
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

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.test-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir, identifiers: ["com.test.test-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
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
                "type": "static",
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

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.fail-plugin", "com.test.ok-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.fail-plugin", "com.test.ok-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
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
            "type": "static",
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

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.secret-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.secret-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(), // no secrets configured
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == false)
    }

    @Test("skip rule prevents binary execution for matched image")
    func skipRulePreventsBinary() async throws {
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-skip-marker-\(UUID().uuidString)")
        let script = try makeTempScript("""
            [ "$1" = "--piqley-info" ] && exit 1
            touch "\(markerPath.path)"
            """)
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

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["pre-process"] = ["com.test.skip-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.skip-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow, pluginsDirectory: pluginsDir, secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == true)
        #expect(!FileManager.default.fileExists(atPath: markerPath.path))
    }

    @Test("buildStatePayload excludes skipped images")
    func buildStatePayloadExcludesSkipped() async throws {
        let stateStore = StateStore()
        await stateStore.setNamespace(
            image: "keep.jpg", plugin: "original",
            values: ["IPTC:Keywords": .array([.string("Landscape")])]
        )
        await stateStore.setNamespace(
            image: "skip.jpg", plugin: "original",
            values: ["IPTC:Keywords": .array([.string("Draft")])]
        )

        let orchestrator = PipelineOrchestrator(
            workflow: .empty(name: "test", activeStages: StandardHook.defaultStageNames),
            pluginsDirectory: FileManager.default.temporaryDirectory,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: FileManager.default.temporaryDirectory
        )

        let payload = await orchestrator.buildStatePayload(
            proto: .json,
            hasEnvironmentMapping: false,
            manifestDeps: [],
            pluginIdentifier: "com.test",
            rulesDidRun: true,
            stateStore: stateStore,
            skippedImages: ["skip.jpg"]
        )

        #expect(payload != nil)
        #expect(payload?["keep.jpg"] != nil)
        #expect(payload?["skip.jpg"] == nil)
    }

    @Test("skipped image file is removed from image folder before downstream binary")
    func skippedImageRemovedFromFolder() async throws {
        // Plugin A: pre-process with a skip rule matching "Draft" keyword
        let pluginAScript = try makeTempScript("exit 0")
        defer { try? FileManager.default.removeItem(at: pluginAScript) }
        let pluginsDir = try makePluginsDirWithSkipRule(
            identifier: "com.test.skipper", hook: "pre-process", scriptURL: pluginAScript
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        // Plugin B: publish stage — writes the list of image files it sees to a marker file
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-seen-\(UUID().uuidString)")
        let pluginBScript = try makeTempScript("""
            ls "$PIQLEY_IMAGE_FOLDER_PATH" > "\(markerPath.path)"
            """)
        defer { try? FileManager.default.removeItem(at: pluginBScript) }

        // Add plugin B to pluginsDir
        let pluginBDir = pluginsDir.appendingPathComponent("com.test.publisher")
        try FileManager.default.createDirectory(at: pluginBDir, withIntermediateDirectories: true)
        let manifestB: [String: Any] = [
            "identifier": "com.test.publisher",
            "name": "publisher",
            "type": "static",
            "pluginSchemaVersion": "1"
        ]
        try JSONSerialization.data(withJSONObject: manifestB)
            .write(to: pluginBDir.appendingPathComponent("manifest.json"))
        let stageBConfig: [String: Any] = [
            "binary": ["command": pluginBScript.path, "args": [], "protocol": "pipe"]
        ]
        try JSONSerialization.data(withJSONObject: stageBConfig)
            .write(to: pluginBDir.appendingPathComponent("stage-publish.json"))
        try FileManager.default.createDirectory(
            at: pluginBDir.appendingPathComponent("data"), withIntermediateDirectories: true
        )

        // Source dir with two images: one with Draft keyword (should be skipped), one without
        let sourceDir = try makeSourceDir(withImage: false)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        try TestFixtures.createTestJPEG(
            at: sourceDir.appendingPathComponent("draft.jpg").path,
            keywords: ["Draft-Photo"]
        )
        try TestFixtures.createTestJPEG(
            at: sourceDir.appendingPathComponent("keep.jpg").path
        )

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["pre-process"] = ["com.test.skipper"]
        workflow.pipeline["publish"] = ["com.test.publisher"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.skipper", "com.test.publisher"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow, pluginsDirectory: pluginsDir, secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == true)

        // The marker file should list only keep.jpg, not draft.jpg
        let seen = try String(contentsOf: markerPath, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        #expect(seen.contains("keep.jpg"))
        #expect(!seen.contains("draft.jpg"))
    }

    @Test("critical failure stops remaining plugins in the same stage")
    func testCriticalAbortsSameStage() async throws {
        let failScript = try makeTempScript("exit 1")
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-same-stage-marker-\(UUID().uuidString)")
        let successScript = try makeTempScript("""
            [ "$1" = "--piqley-info" ] && exit 1
            touch "\(markerPath.path)"
            """)
        defer {
            try? FileManager.default.removeItem(at: failScript)
            try? FileManager.default.removeItem(at: successScript)
            try? FileManager.default.removeItem(at: markerPath)
        }

        // Two plugins in the SAME stage: first fails critically, second should never run
        let pluginsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-orch-\(UUID().uuidString)")

        for (identifier, script) in [("com.test.fail-plugin", failScript), ("com.test.ok-plugin", successScript)] {
            let pluginDir = pluginsDir.appendingPathComponent(identifier)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "identifier": identifier,
                "name": identifier,
                "type": "static",
                "pluginSchemaVersion": "1"
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: pluginDir.appendingPathComponent("manifest.json"))
            let stageConfig: [String: Any] = [
                "binary": ["command": script.path, "args": [], "protocol": "pipe"]
            ]
            try JSONSerialization.data(withJSONObject: stageConfig)
                .write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))
            try FileManager.default.createDirectory(
                at: pluginDir.appendingPathComponent("data"), withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: pluginsDir) }

        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["pre-process"] = ["com.test.fail-plugin", "com.test.ok-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.fail-plugin", "com.test.ok-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == false)
        // The second plugin must NOT have run — marker file should not exist
        #expect(!FileManager.default.fileExists(atPath: markerPath.path))
    }

    @Test("aliased stage sends resolved hook to plugin binary")
    func aliasedStageSendsResolvedHook() async throws {
        // Create a script that writes the PIQLEY_HOOK env var to a file
        let hookFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-hook-\(UUID().uuidString).txt")
        let script = try makeTempScript("echo $PIQLEY_HOOK > \(hookFile.path)")

        // Stage file is named stage-publish-365.json (keyed by stage name)
        let pluginsDir = try makePluginsDir(
            withPlugin: "com.test.alias-plugin",
            hook: "publish-365",
            scriptURL: script
        )

        // The alias points stage "publish-365" to hook "publish"
        // so the plugin binary should receive "publish" as PIQLEY_HOOK
        let registry = StageRegistry(
            active: [
                StageEntry(name: "pipeline-start"),
                StageEntry(name: "publish-365", hook: "publish"),
                StageEntry(name: "pipeline-finished")
            ]
        )

        let sourceDir = try makeSourceDir()
        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test",
            pluginsDir: pluginsDir,
            identifiers: ["com.test.alias-plugin"]
        )

        let workflow = Workflow(
            name: "test",
            displayName: "test",
            description: "test",
            pipeline: ["publish-365": ["com.test.alias-plugin"]]
        )

        let secretStore = FakeSecretStore()
        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: secretStore,
            registry: registry,
            workflowsRoot: workflowsRoot
        )

        _ = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)

        let hookValue = try String(contentsOf: hookFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(hookValue == "publish")
    }

    @Test("pipeline-finished is invoked automatically for plugins with binaries")
    func testPipelineFinishedAutoInvoked() async throws {
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-lifecycle-\(UUID().uuidString)")
        let script = try makeTempScript("""
            if [ "$PIQLEY_HOOK" = "pipeline-finished" ]; then
                echo "finished" >> "\(markerPath.path)"
            fi
            echo '{"type":"result"}'
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(
            withPlugin: "com.test.lifecycle-plugin", hook: "publish", scriptURL: script
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.lifecycle-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.lifecycle-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == true)
        let marker = try String(contentsOf: markerPath, encoding: .utf8)
        #expect(marker.contains("finished"))
    }

    @Test("pipeline-start is invoked automatically before main stages")
    func testPipelineStartAutoInvoked() async throws {
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-start-\(UUID().uuidString)")
        let script = try makeTempScript("""
            if [ "$PIQLEY_HOOK" = "pipeline-start" ]; then
                echo "started" >> "\(markerPath.path)"
            fi
            echo '{"type":"result"}'
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(
            withPlugin: "com.test.start-plugin", hook: "publish", scriptURL: script
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.start-plugin"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.start-plugin"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == true)
        let marker = try String(contentsOf: markerPath, encoding: .utf8)
        #expect(marker.contains("started"))
    }

    @Test("pipeline-start failure aborts pipeline")
    func testPipelineStartFailureAborts() async throws {
        let mainMarkerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-main-\(UUID().uuidString)")
        let script = try makeTempScript("""
            if [ "$PIQLEY_HOOK" = "pipeline-start" ]; then
                echo '{"type":"result"}'
                exit 1
            fi
            if [ "$PIQLEY_HOOK" = "publish" ]; then
                touch "\(mainMarkerPath.path)"
            fi
            echo '{"type":"result"}'
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(
            withPlugin: "com.test.fail-start", hook: "publish", scriptURL: script
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.fail-start"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.fail-start"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == false)
        #expect(!FileManager.default.fileExists(atPath: mainMarkerPath.path))
    }

    @Test("pipeline-finished runs even when main pipeline fails")
    func testPipelineFinishedRunsAfterFailure() async throws {
        let finishMarkerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-finish-after-fail-\(UUID().uuidString)")
        let script = try makeTempScript("""
            if [ "$PIQLEY_HOOK" = "pipeline-finished" ]; then
                echo "cleanup" >> "\(finishMarkerPath.path)"
                echo '{"type":"result"}'
                exit 0
            fi
            echo '{"type":"result"}'
            if [ "$PIQLEY_HOOK" = "publish" ]; then
                exit 1
            fi
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(
            withPlugin: "com.test.fail-publish", hook: "publish", scriptURL: script
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.fail-publish"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.fail-publish"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == false)
        let marker = try String(contentsOf: finishMarkerPath, encoding: .utf8)
        #expect(marker.contains("cleanup"))
    }

    @Test("pipeline-finished failure does not affect pipeline result")
    func testPipelineFinishedFailureIsBestEffort() async throws {
        let script = try makeTempScript("""
            echo '{"type":"result"}'
            if [ "$PIQLEY_HOOK" = "pipeline-finished" ]; then
                exit 1
            fi
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let pluginsDir = try makePluginsDir(
            withPlugin: "com.test.finish-fail", hook: "publish", scriptURL: script
        )
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let sourceDir = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var workflow = Workflow.empty(name: "test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["com.test.finish-fail"]

        let workflowsRoot = try makeWorkflowsRoot(
            workflowName: "test", pluginsDir: pluginsDir,
            identifiers: ["com.test.finish-fail"]
        )
        defer { try? FileManager.default.removeItem(at: workflowsRoot) }

        let orchestrator = PipelineOrchestrator(
            workflow: workflow,
            pluginsDirectory: pluginsDir,
            secretStore: FakeSecretStore(),
            registry: StageRegistry(active: StandardHook.defaultStageNames.map { StageEntry(name: $0) }),
            workflowsRoot: workflowsRoot
        )
        let result = try await orchestrator.run(sourceURL: sourceDir, dryRun: false, debug: false)
        #expect(result == true)
    }
}
