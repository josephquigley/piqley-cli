# Skip Image Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove globally skipped images from the working image folder and state payload so plugin binaries never see them.

**Architecture:** Two targeted changes in the CLI's pipeline orchestrator. After pre-rules evaluate and before the binary runs, delete skipped image files from `imageFolderURL`. Pass the `skippedImages` set into `buildStatePayload` so it filters those entries out. No SDK, plugin, or PiqleyCore changes.

**Tech Stack:** Swift, Swift Testing framework

---

### Task 1: Add `skippedImages` parameter to `buildStatePayload`

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift:8-32` (buildStatePayload)
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift:263-268` (call site in runBinary)
- Test: `Tests/piqleyTests/PipelineOrchestratorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PipelineOrchestratorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "buildStatePayloadExcludesSkipped"`
Expected: FAIL — `buildStatePayload` does not accept a `skippedImages` parameter.

- [ ] **Step 3: Add `skippedImages` parameter to `buildStatePayload`**

In `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`, change the function signature and add the filter:

```swift
func buildStatePayload(
    proto: PluginProtocol,
    hasEnvironmentMapping: Bool = false,
    manifestDeps: [String],
    pluginIdentifier: String,
    rulesDidRun: Bool,
    stateStore: StateStore,
    skippedImages: Set<String> = []
) async -> [String: [String: [String: JSONValue]]]? {
    let needsState = hasEnvironmentMapping || (proto == .json && (!manifestDeps.isEmpty || rulesDidRun))
    guard needsState else { return nil }

    var statePayload: [String: [String: [String: JSONValue]]] = [:]
    let allDeps = rulesDidRun
        ? manifestDeps + [ReservedName.original, pluginIdentifier, ReservedName.skip]
        : manifestDeps + [ReservedName.original, ReservedName.skip]
    for imageName in await stateStore.allImageNames {
        if skippedImages.contains(imageName) { continue }
        let resolved = await stateStore.resolve(
            image: imageName, dependencies: allDeps
        )
        if !resolved.isEmpty {
            statePayload[imageName] = resolved
        }
    }
    return statePayload.isEmpty ? nil : statePayload
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "buildStatePayloadExcludesSkipped"`
Expected: PASS

- [ ] **Step 5: Commit**

Message: `feat: filter skipped images from state payload in buildStatePayload`

---

### Task 2: Pass `skippedImages` through `runBinary` to `buildStatePayload`

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift:239-268` (runBinary signature and call site)
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift:310-318` (runBinary call site in runPluginHook)

- [ ] **Step 1: Add `skippedImages` parameter to `runBinary`**

In `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`, add the parameter to `runBinary`:

```swift
func runBinary(
    _ ctx: HookContext,
    loadedPlugin: LoadedPlugin,
    secrets: [String: String],
    pluginConfig: PluginConfig,
    hookConfig: HookConfig?,
    manifestDeps: [String],
    rulesDidRun: Bool,
    execLogPath: URL,
    skipped: [SkipRecord] = [],
    skippedImages: Set<String> = [],
    imageFolderURL: URL? = nil,
    metadataBuffer: MetadataBuffer? = nil,
    pipelineRunId: String? = nil
) async throws -> (HookResult, [String]) {
```

Then pass it through to `buildStatePayload`:

```swift
let pluginState = await buildStatePayload(
    proto: proto, hasEnvironmentMapping: hasEnvironmentMapping,
    manifestDeps: manifestDeps,
    pluginIdentifier: ctx.pluginIdentifier, rulesDidRun: rulesDidRun,
    stateStore: ctx.stateStore,
    skippedImages: skippedImages
)
```

- [ ] **Step 2: Pass `skippedImages` at the call site in `runPluginHook`**

In `Sources/piqley/Pipeline/PipelineOrchestrator.swift`, update the `runBinary` call (around line 310):

```swift
let (result, runtimeSkips) = try await runBinary(
    ctx, loadedPlugin: loadedPlugin,
    secrets: secrets, pluginConfig: pluginConfig,
    hookConfig: stageConfig.binary, manifestDeps: manifestDeps,
    rulesDidRun: preRulesDidRun, execLogPath: execLogPath,
    skipped: skipRecords,
    skippedImages: skippedImages,
    imageFolderURL: imageFolderURL,
    metadataBuffer: buffer,
    pipelineRunId: ctx.pipelineRunId
)
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 4: Run existing tests to verify no regressions**

Run: `swift test --filter "PipelineOrchestrator"`
Expected: All existing tests pass.

- [ ] **Step 5: Commit**

Message: `refactor: thread skippedImages through runBinary to buildStatePayload`

---

### Task 3: Remove skipped image files from the image folder before binary execution

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift:278-291` (between buffer.flush() and binary execution)
- Test: `Tests/piqleyTests/PipelineOrchestratorTests.swift`

- [ ] **Step 1: Write the failing test**

This test sets up a two-stage pipeline: plugin A in `pre-process` skips an image via a skip rule, and plugin B in `publish` uses a marker file to detect if it was invoked with that image. The key difference from the existing `skipRulePreventsBinary` test is that we have *two* images: one skipped, one not. The binary should only see the non-skipped image.

Add to `PipelineOrchestratorTests.swift`:

```swift
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
        ls "$PIQLEY_IMAGE_FOLDER" > "\(markerPath.path)"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "skippedImageRemovedFromFolder"`
Expected: FAIL — `draft.jpg` is still listed in the marker file.

- [ ] **Step 3: Add skip image removal in `runPluginHook`**

In `Sources/piqley/Pipeline/PipelineOrchestrator.swift`, after the `await buffer.flush()` line (line 279) and before the `// Binary` comment (line 281), add:

```swift
// Remove skipped images from the image folder so the binary never sees them
for imageName in skippedImages {
    let imageURL = imageFolderURL.appendingPathComponent(imageName)
    try? FileManager.default.removeItem(at: imageURL)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "skippedImageRemovedFromFolder"`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

Message: `fix: remove skipped images from working folder before plugin binary execution`
