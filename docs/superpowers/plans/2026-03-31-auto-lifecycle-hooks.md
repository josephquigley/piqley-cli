# Auto Lifecycle Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `pipeline-start` and `pipeline-finished` automatic for all plugins with binaries, instead of requiring manual workflow configuration.

**Architecture:** The orchestrator gets a three-phase structure: lifecycle-start, main stage loop (skipping lifecycle stages), lifecycle-finished (always runs, best-effort). The TUI and workflow config strip lifecycle stages from user-visible surfaces. All filtering uses the existing `StandardHook.requiredStageNames` set — no changes to piqley-core.

**Tech Stack:** Swift 6.0, Swift Testing framework, piqley-cli

---

### File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/piqley/Pipeline/PipelineOrchestrator.swift` | Modify | Three-phase execution, lifecycle plugin collection |
| `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift` | Modify | Add `runLifecycleHook` helper, update `validateBinaries` |
| `Sources/piqley/Config/Workflow.swift` | Modify | `empty()` excludes lifecycle stages, add `strippingLifecycleStages()` |
| `Sources/piqley/Config/WorkflowStore.swift` | Modify | Strip lifecycle stages on save |
| `Sources/piqley/Wizard/ConfigWizard.swift` | Modify | Filter lifecycle stages from `stageSelect()` |
| `Sources/piqley/Wizard/ConfigWizard+Stages.swift` | Modify | Filter lifecycle stages from `drawStageScreen()` |
| `Sources/piqley/Wizard/ConfigWizard+Plugins.swift` | Modify | Filter lifecycle stages from "add to stage" picker |
| `Tests/piqleyTests/PipelineOrchestratorTests.swift` | Modify | Add lifecycle hook tests |
| `Tests/piqleyTests/ConfigTests.swift` | Modify | Update empty workflow test |

---

### Task 1: Add lifecycle stage filtering to Workflow

**Files:**
- Modify: `Sources/piqley/Config/Workflow.swift`
- Modify: `Tests/piqleyTests/ConfigTests.swift`

- [ ] **Step 1: Update the empty workflow test to expect 4 stages instead of 6**

In `Tests/piqleyTests/ConfigTests.swift`, update the `testEmptyWorkflow` test:

```swift
@Test("empty workflow has user-configurable hooks only")
func testEmptyWorkflow() {
    let workflow = Workflow.empty(name: "default", activeStages: StandardHook.defaultStageNames)
    #expect(workflow.pipeline.count == 4)
    #expect(workflow.pipeline["pipeline-start"] == nil)
    #expect(workflow.pipeline["pre-process"] == [])
    #expect(workflow.pipeline["post-process"] == [])
    #expect(workflow.pipeline["publish"] == [])
    #expect(workflow.pipeline["post-publish"] == [])
    #expect(workflow.pipeline["pipeline-finished"] == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigTests/testEmptyWorkflow 2>&1 | tail -20`
Expected: FAIL — currently creates 6 stages including lifecycle stages.

- [ ] **Step 3: Update `Workflow.empty()` to filter out lifecycle stages**

In `Sources/piqley/Config/Workflow.swift`, update the `empty` factory:

```swift
static func empty(name: String, displayName: String = "", description: String = "", activeStages: [String]) -> Workflow {
    let userStages = activeStages.filter { !StandardHook.requiredStageNames.contains($0) }
    return Workflow(
        name: name,
        displayName: displayName.isEmpty ? name : displayName,
        description: description,
        pipeline: Dictionary(uniqueKeysWithValues: userStages.map { ($0, [String]()) })
    )
}
```

- [ ] **Step 4: Add `strippingLifecycleStages()` method**

Below the `empty` factory in `Workflow.swift`, add:

```swift
/// Returns a copy with lifecycle stage keys removed from the pipeline.
func strippingLifecycleStages() -> Workflow {
    var copy = self
    for stage in StandardHook.requiredStageNames {
        copy.pipeline.removeValue(forKey: stage)
    }
    return copy
}
```

- [ ] **Step 5: Add test for stripping lifecycle stages**

In `Tests/piqleyTests/ConfigTests.swift`, add:

```swift
@Test("strippingLifecycleStages removes pipeline-start and pipeline-finished")
func testStrippingLifecycleStages() {
    var workflow = Workflow(
        name: "test", displayName: "test", description: "",
        pipeline: [
            "pipeline-start": ["com.test.plugin"],
            "pre-process": ["com.test.plugin"],
            "publish": ["com.test.plugin"],
            "pipeline-finished": ["com.test.plugin"]
        ]
    )
    let stripped = workflow.strippingLifecycleStages()
    #expect(stripped.pipeline["pipeline-start"] == nil)
    #expect(stripped.pipeline["pipeline-finished"] == nil)
    #expect(stripped.pipeline["pre-process"] == ["com.test.plugin"])
    #expect(stripped.pipeline["publish"] == ["com.test.plugin"])
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ConfigTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 7: Commit**

```
feat: exclude lifecycle stages from Workflow.empty() and add stripping helper
```

---

### Task 2: Strip lifecycle stages on workflow save

**Files:**
- Modify: `Sources/piqley/Config/WorkflowStore.swift`
- Modify: `Tests/piqleyTests/WorkflowStoreTests.swift`

- [ ] **Step 1: Write failing test for lifecycle stripping on save**

In `Tests/piqleyTests/WorkflowStoreTests.swift`, add:

```swift
@Test("save strips lifecycle stages from pipeline")
func testSaveStripsLifecycleStages() throws {
    let workflow = Workflow(
        name: "strip-test", displayName: "strip-test", description: "",
        pipeline: [
            "pipeline-start": ["com.test.plugin"],
            "pre-process": ["com.test.plugin"],
            "pipeline-finished": ["com.test.plugin"]
        ]
    )
    try WorkflowStore.save(workflow, root: testDir)
    let reloaded = try WorkflowStore.load(name: "strip-test", root: testDir)
    #expect(reloaded.pipeline["pipeline-start"] == nil)
    #expect(reloaded.pipeline["pipeline-finished"] == nil)
    #expect(reloaded.pipeline["pre-process"] == ["com.test.plugin"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkflowStoreTests/testSaveStripsLifecycleStages 2>&1 | tail -20`
Expected: FAIL — lifecycle stages are currently preserved.

- [ ] **Step 3: Update `WorkflowStore.save` to strip lifecycle stages**

In `Sources/piqley/Config/WorkflowStore.swift`, update the `save` method:

```swift
static func save(_ workflow: Workflow, root: URL? = nil) throws {
    let dir = directoryURL(name: workflow.name, root: root)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cleaned = workflow.strippingLifecycleStages()
    let data = try JSONEncoder.piqleyPrettyPrint.encode(cleaned)
    try data.write(to: fileURL(name: workflow.name, root: root))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WorkflowStoreTests/testSaveStripsLifecycleStages 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run all WorkflowStore tests**

Run: `swift test --filter WorkflowStoreTests 2>&1 | tail -30`
Expected: PASS (existing tests should still work since they don't rely on lifecycle stage keys)

- [ ] **Step 6: Commit**

```
feat: strip lifecycle stages from workflow on save
```

---

### Task 3: Add `runLifecycleHook` helper to orchestrator

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`

- [ ] **Step 1: Add `collectLifecyclePlugins` method**

At the end of `PipelineOrchestrator+Helpers.swift` (before the closing of the extension or before `PipelineError`), add:

```swift
// MARK: - Lifecycle Hooks

/// Collects the unique set of plugin identifiers from the workflow that have a binary.
func collectLifecyclePlugins() throws -> [String] {
    let userStages = workflow.pipeline.filter { !StandardHook.requiredStageNames.contains($0.key) }
    let uniqueIdentifiers = Set(userStages.values.flatMap(\.self))
    return uniqueIdentifiers.filter { identifier in
        guard let plugin = try? loadPlugin(named: identifier) else { return false }
        return plugin.stages.values.contains { stageConfig in
            if let command = stageConfig.binary?.command, !command.isEmpty {
                return true
            }
            return false
        }
    }.sorted() // sorted for deterministic logging, order doesn't matter for execution
}
```

- [ ] **Step 2: Add `runLifecycleHook` method**

Below `collectLifecyclePlugins`, add:

```swift
/// Invokes a lifecycle hook for a single plugin. Returns `.critical` on failure, `.success` otherwise.
func runLifecycleHook(
    pluginIdentifier: String,
    hook: StandardHook,
    temp: TempFolder,
    imageFiles: [URL],
    dryRun: Bool,
    debug: Bool,
    pipelineRunId: String
) async throws -> HookResult {
    guard let loadedPlugin = try loadPlugin(named: pluginIdentifier) else {
        logger.warning("[\(pluginIdentifier)] not found for lifecycle hook \(hook.rawValue)")
        return .pluginNotFound
    }

    // Find the plugin's binary command from any stage that has one
    guard let binaryCommand = loadedPlugin.stages.values.lazy.compactMap({ $0.binary?.command }).first(where: { !$0.isEmpty }) else {
        logger.debug("[\(pluginIdentifier)] no binary found for lifecycle hook \(hook.rawValue)")
        return .skipped
    }

    let configResult = resolvePluginConfigAndSecrets(
        plugin: loadedPlugin, pluginIdentifier: pluginIdentifier
    )
    let secrets: [String: String]
    let pluginConfig: PluginConfig
    switch configResult {
    case let .resolved(sec, conf):
        secrets = sec
        pluginConfig = conf
    case .secretMissing:
        return .secretMissing
    }

    let hookConfig = HookConfig(command: binaryCommand, args: nil, pluginProtocol: .json, environment: nil)

    let execLogPath = pluginsDirectory
        .appendingPathComponent(pluginIdentifier)
        .appendingPathComponent(PluginFile.executionLog)
    try FileManager.default.createDirectory(
        at: execLogPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let stateStore = StateStore()
    let ctx = HookContext(
        pluginIdentifier: pluginIdentifier,
        pluginName: loadedPlugin.name,
        hook: hook.rawValue,
        stage: hook.rawValue,
        temp: temp,
        stateStore: stateStore,
        imageFiles: imageFiles,
        dryRun: dryRun,
        debug: debug,
        nonInteractive: true,
        skippedImages: [],
        executedPlugins: [],
        pipelineRunId: pipelineRunId
    )

    let (result, _) = try await runBinary(
        ctx,
        loadedPlugin: loadedPlugin,
        secrets: secrets,
        pluginConfig: pluginConfig,
        hookConfig: hookConfig,
        manifestDeps: [],
        rulesDidRun: false,
        execLogPath: execLogPath,
        pipelineRunId: pipelineRunId
    )
    return result
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds (methods are added but not yet called).

- [ ] **Step 4: Commit**

```
feat: add lifecycle hook collection and invocation helpers
```

---

### Task 4: Implement three-phase orchestrator

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift`

- [ ] **Step 1: Write failing test for automatic pipeline-finished invocation**

In `Tests/piqleyTests/PipelineOrchestratorTests.swift`, add a new test:

```swift
@Test("pipeline-finished is invoked automatically for plugins with binaries")
func testPipelineFinishedAutoInvoked() async throws {
    let markerPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-lifecycle-\(UUID().uuidString)")
    // Script writes the hook name to a marker file when invoked with pipeline-finished
    let script = try makeTempScript("""
        if [ "$PIQLEY_HOOK" = "pipeline-finished" ]; then
            echo "finished" >> "\(markerPath.path)"
        fi
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
    // Note: pipeline-finished is NOT in the workflow — it should be auto-invoked

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PipelineOrchestratorTests/testPipelineFinishedAutoInvoked 2>&1 | tail -20`
Expected: FAIL — marker file does not exist because `pipeline-finished` is not invoked.

- [ ] **Step 3: Implement three-phase orchestrator in `run()`**

Replace the main execution section of `PipelineOrchestrator.run()` (from `// Execute hooks in order from registry` through the end of the for loop, and adjust the pipeline-failed handling). The full `run()` method becomes:

```swift
func run(sourceURL: URL, dryRun: Bool, debug: Bool, nonInteractive: Bool = false, overwriteSource: Bool = false) async throws -> Bool {
    let pipeline = workflow.pipeline
    let pipelineRunId = UUID().uuidString

    // Create temp folder and copy images
    let temp = try TempFolder.create()
    logger.info("Temp folder: \(temp.url.path)")
    let copyResult: TempFolder.CopyResult
    do {
        copyResult = try temp.copyImages(from: sourceURL)
    } catch {
        try? temp.delete()
        throw error
    }
    for skipped in copyResult.skippedFiles {
        logger.warning("Skipping '\(skipped)': unsupported format")
    }
    if copyResult.copiedCount == 0 {
        logger.error("No supported image files found in \(sourceURL.path)")
        try? temp.delete()
        return false
    }

    let blocklist = PluginBlocklist()
    let stateStore = StateStore()
    var ruleEvaluatorCache: [String: RuleEvaluator] = [:]

    // Extract metadata from all images into original namespace
    let imageFiles = try FileManager.default.contentsOfDirectory(
        at: temp.url, includingPropertiesForKeys: nil
    ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

    for imageFile in imageFiles {
        let metadata = MetadataExtractor.extract(from: imageFile)
        await stateStore.setNamespace(
            image: imageFile.lastPathComponent,
            plugin: ReservedName.original,
            values: metadata
        )
    }

    // Validate plugin dependencies
    do {
        try validateDependencies(pipeline: pipeline)
    } catch is PipelineError {
        try? temp.delete()
        return false
    }

    // Validate all binaries before starting
    do {
        try validateBinaries(pipeline: pipeline)
    } catch is PipelineError {
        try? temp.delete()
        return false
    }

    defer {
        do {
            try temp.delete()
            logger.debug("Temp folder deleted")
        } catch {
            logger.warning("Failed to delete temp folder: \(error)")
        }
    }

    // Collect plugins eligible for lifecycle hooks
    let lifecyclePlugins: [String]
    do {
        lifecyclePlugins = try collectLifecyclePlugins()
    } catch {
        logger.error("Failed to collect lifecycle plugins: \(error)")
        return false
    }

    logger.info("Pipeline run \(pipelineRunId) starting")

    // === Phase 1: pipeline-start (failure aborts pipeline) ===
    for pluginId in lifecyclePlugins {
        let result = try await runLifecycleHook(
            pluginIdentifier: pluginId,
            hook: .pipelineStart,
            temp: temp,
            imageFiles: imageFiles,
            dryRun: dryRun,
            debug: debug,
            pipelineRunId: pipelineRunId
        )
        switch result {
        case .success, .warning, .skipped:
            break
        case .pluginNotFound, .secretMissing, .ruleCompilationFailed, .critical:
            logger.error("[\(pluginId)] pipeline-start failed — aborting pipeline")
            // Still run pipeline-finished for cleanup
            for finishPluginId in lifecyclePlugins {
                _ = try? await runLifecycleHook(
                    pluginIdentifier: finishPluginId,
                    hook: .pipelineFinished,
                    temp: temp,
                    imageFiles: imageFiles,
                    dryRun: dryRun,
                    debug: debug,
                    pipelineRunId: pipelineRunId
                )
            }
            return false
        }
    }

    // === Phase 2: main stage loop (skip lifecycle stages) ===
    var skippedImages: Set<String> = []
    var executedPlugins: [(hook: String, pluginId: String)] = []
    var pipelineFailed = false

    for stage in registry.executionOrder {
        // Skip lifecycle stages — they are handled in phases 1 and 3
        guard !StandardHook.requiredStageNames.contains(stage) else { continue }
        guard !pipelineFailed else { break }

        for pluginEntry in pipeline[stage] ?? [] {
            guard !pipelineFailed else { break }
            guard !blocklist.isBlocked(pluginEntry) else {
                logger.debug("[\(pluginEntry)] skipped (blocklisted)")
                continue
            }

            let resolvedHook = registry.resolvedHook(for: stage)
            let ctx = HookContext(
                pluginIdentifier: pluginEntry, pluginName: pluginEntry,
                hook: resolvedHook, stage: stage, temp: temp,
                stateStore: stateStore, imageFiles: imageFiles,
                dryRun: dryRun, debug: debug, nonInteractive: nonInteractive,
                skippedImages: skippedImages,
                executedPlugins: executedPlugins,
                pipelineRunId: pipelineRunId
            )
            let (result, updatedSkipped) = try await runPluginHook(ctx, ruleEvaluatorCache: &ruleEvaluatorCache)
            skippedImages = updatedSkipped

            switch result {
            case .success, .warning, .skipped:
                executedPlugins.append((hook: stage, pluginId: pluginEntry))
            case .pluginNotFound, .secretMissing, .ruleCompilationFailed, .critical:
                blocklist.block(pluginEntry)
                pipelineFailed = true
            }
        }
    }

    // === Phase 3: pipeline-finished (always runs, best-effort) ===
    for pluginId in lifecyclePlugins {
        do {
            let result = try await runLifecycleHook(
                pluginIdentifier: pluginId,
                hook: .pipelineFinished,
                temp: temp,
                imageFiles: imageFiles,
                dryRun: dryRun,
                debug: debug,
                pipelineRunId: pipelineRunId
            )
            if case .critical = result {
                logger.warning("[\(pluginId)] pipeline-finished returned critical — ignoring")
            }
        } catch {
            logger.warning("[\(pluginId)] pipeline-finished threw error: \(error) — ignoring")
        }
    }

    logger.info("Pipeline run \(pipelineRunId) finished")

    if pipelineFailed {
        return false
    }

    // Copy processed images back to source if requested
    if overwriteSource {
        try temp.copyBack(to: sourceURL)
        logger.info("Copied processed images back to \(sourceURL.path)")
    }

    return true
}
```

- [ ] **Step 4: Also update `runPluginHook` — persist version after pipeline-start**

The existing `runPluginHook` has version persistence code that checks `if ctx.stage == StandardHook.pipelineStart.rawValue`. Since `pipeline-start` is no longer dispatched through `runPluginHook`, this code is now dead. Remove the version persistence block (lines 328-339 in the original) from `runPluginHook`:

Remove this block from `runPluginHook`:
```swift
// Persist version after successful pipeline-start
if ctx.stage == StandardHook.pipelineStart.rawValue {
    let pluginVersion = loadedPlugin.manifest.pluginVersion
        ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    do {
        try versionStateStore.save(version: pluginVersion, for: ctx.pluginIdentifier)
    } catch {
        logger.warning(
            "[\(loadedPlugin.name)] failed to save version state: \(error)"
        )
    }
}
```

And add version persistence to `runLifecycleHook` in `PipelineOrchestrator+Helpers.swift`, right after the `runBinary` call but only for `pipeline-start`:

```swift
// Persist version after successful pipeline-start
if hook == .pipelineStart {
    switch result {
    case .success, .warning:
        let pluginVersion = loadedPlugin.manifest.pluginVersion
            ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        do {
            try versionStateStore.save(version: pluginVersion, for: pluginIdentifier)
        } catch {
            logger.warning(
                "[\(loadedPlugin.name)] failed to save version state: \(error)"
            )
        }
    default:
        break
    }
}
```

- [ ] **Step 5: Run the failing test**

Run: `swift test --filter PipelineOrchestratorTests/testPipelineFinishedAutoInvoked 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 6: Commit**

```
feat: implement three-phase pipeline with auto lifecycle hooks
```

---

### Task 5: Add pipeline-start and failure-path tests

**Files:**
- Modify: `Tests/piqleyTests/PipelineOrchestratorTests.swift`

- [ ] **Step 1: Write test for pipeline-start auto-invocation**

```swift
@Test("pipeline-start is invoked automatically before main stages")
func testPipelineStartAutoInvoked() async throws {
    let markerPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-start-\(UUID().uuidString)")
    let script = try makeTempScript("""
        if [ "$PIQLEY_HOOK" = "pipeline-start" ]; then
            echo "started" >> "\(markerPath.path)"
        fi
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
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter PipelineOrchestratorTests/testPipelineStartAutoInvoked 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 3: Write test for pipeline-start failure aborting pipeline**

```swift
@Test("pipeline-start failure aborts pipeline")
func testPipelineStartFailureAborts() async throws {
    let mainMarkerPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-main-\(UUID().uuidString)")
    // Script that fails on pipeline-start, succeeds on other hooks
    let script = try makeTempScript("""
        if [ "$PIQLEY_HOOK" = "pipeline-start" ]; then
            exit 1
        fi
        touch "\(mainMarkerPath.path)"
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
    // Main stage binary should NOT have run
    #expect(!FileManager.default.fileExists(atPath: mainMarkerPath.path))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PipelineOrchestratorTests/testPipelineStartFailureAborts 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Write test for pipeline-finished running even after main loop failure**

```swift
@Test("pipeline-finished runs even when main pipeline fails")
func testPipelineFinishedRunsAfterFailure() async throws {
    let finishMarkerPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-finish-after-fail-\(UUID().uuidString)")
    // Script: fails on publish, writes marker on pipeline-finished
    let script = try makeTempScript("""
        if [ "$PIQLEY_HOOK" = "pipeline-finished" ]; then
            echo "cleanup" >> "\(finishMarkerPath.path)"
            exit 0
        fi
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
    // pipeline-finished SHOULD have run despite publish failure
    let marker = try String(contentsOf: finishMarkerPath, encoding: .utf8)
    #expect(marker.contains("cleanup"))
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter PipelineOrchestratorTests/testPipelineFinishedRunsAfterFailure 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 7: Write test for pipeline-finished failure being best-effort**

```swift
@Test("pipeline-finished failure does not affect pipeline result")
func testPipelineFinishedFailureIsBestEffort() async throws {
    // Script: succeeds on publish, fails on pipeline-finished
    let script = try makeTempScript("""
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
    // Pipeline should still succeed even though pipeline-finished failed
    #expect(result == true)
}
```

- [ ] **Step 8: Run all orchestrator tests**

Run: `swift test --filter PipelineOrchestratorTests 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 9: Commit**

```
test: add lifecycle hook auto-invocation and error semantics tests
```

---

### Task 6: Filter lifecycle stages from TUI

**Files:**
- Modify: `Sources/piqley/Wizard/ConfigWizard.swift`
- Modify: `Sources/piqley/Wizard/ConfigWizard+Stages.swift`
- Modify: `Sources/piqley/Wizard/ConfigWizard+Plugins.swift`

- [ ] **Step 1: Filter lifecycle stages in `stageSelect()`**

In `Sources/piqley/Wizard/ConfigWizard.swift`, in the `stageSelect()` method, change:

```swift
let stages = registry.executionOrder
```

to:

```swift
let stages = registry.executionOrder.filter { !StandardHook.requiredStageNames.contains($0) }
```

- [ ] **Step 2: Filter lifecycle stages in the plugin detail "add to stage" picker**

In `Sources/piqley/Wizard/ConfigWizard+Plugins.swift`, in `showDiscoveredPluginDetail`, change:

```swift
let allStages = registry.executionOrder
```

to:

```swift
let allStages = registry.executionOrder.filter { !StandardHook.requiredStageNames.contains($0) }
```

- [ ] **Step 3: Verify the build compiles**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```
feat: hide lifecycle stages from TUI stage editor and plugin picker
```

---

### Task 7: Run full test suite and fix regressions

**Files:**
- Potentially modify any of the above files if regressions are found

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -40`
Expected: All tests PASS.

- [ ] **Step 2: Fix any regressions**

If any tests fail, diagnose and fix them. Common issues:
- Tests that create workflows with `Workflow.empty()` and expect 6 pipeline keys now get 4
- Tests that reference `pipeline["pipeline-start"]` or `pipeline["pipeline-finished"]` — these keys are no longer created by `empty()`
- The `aliasedStageSendsResolvedHook` test uses a manually constructed `Workflow` (not `empty()`), so it should be unaffected

- [ ] **Step 3: Commit any fixes**

```
fix: update tests for auto lifecycle hooks
```

- [ ] **Step 4: Run the full test suite again to confirm**

Run: `swift test 2>&1 | tail -40`
Expected: All tests PASS.
