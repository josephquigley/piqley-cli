# Stage Hook Aliasing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow custom stages to alias to a plugin-recognized hook, so the plugin binary receives a known hook while the pipeline uses custom stage names for rules, ordering, and logging.

**Architecture:** Add optional `hook` field to `StageEntry` in PiqleyCore. Add `stage` field to `HookContext` in piqley-cli. The orchestrator resolves the alias and threads `stage` vs `hook` through rule lookup, binary execution, logging, and caching.

**Tech Stack:** Swift, PiqleyCore (shared library), piqley-cli

---

### Task 1: Add `hook` field to `StageEntry` and `resolvedHook` to `StageRegistry`

**Files:**
- Modify: `piqley-core :: Sources/PiqleyCore/Config/StageRegistry.swift`
- Test: `piqley-core :: Tests/PiqleyCoreTests/StageRegistryTests.swift`

- [ ] **Step 1: Write failing tests for `StageEntry.hook` and `resolvedHook`**

In `StageRegistryTests.swift`, add after the existing tests:

```swift
@Test func stageEntryRoundTripsWithHook() throws {
    var registry = try StageRegistry.load(from: tempDir)
    registry.active.append(StageEntry(name: "publish-365", hook: "publish"))
    try registry.save(to: tempDir)
    let reloaded = try StageRegistry.load(from: tempDir)
    let entry = reloaded.active.first(where: { $0.name == "publish-365" })
    #expect(entry?.hook == "publish")
}

@Test func stageEntryRoundTripsWithoutHook() throws {
    var registry = try StageRegistry.load(from: tempDir)
    try registry.save(to: tempDir)
    let reloaded = try StageRegistry.load(from: tempDir)
    let entry = reloaded.active.first(where: { $0.name == "publish" })
    #expect(entry?.hook == nil)
}

@Test func resolvedHookReturnsAliasWhenSet() throws {
    var registry = try StageRegistry.load(from: tempDir)
    registry.active.append(StageEntry(name: "publish-365", hook: "publish"))
    #expect(registry.resolvedHook(for: "publish-365") == "publish")
}

@Test func resolvedHookReturnsStageNameWhenNoAlias() throws {
    let registry = try StageRegistry.load(from: tempDir)
    #expect(registry.resolvedHook(for: "publish") == "publish")
}

@Test func resolvedHookReturnsStageNameForUnknownStage() throws {
    let registry = try StageRegistry.load(from: tempDir)
    #expect(registry.resolvedHook(for: "nonexistent") == "nonexistent")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd piqley-core && swift test --filter StageRegistryTests`
Expected: compilation errors (no `hook` parameter on `StageEntry`, no `resolvedHook` method)

- [ ] **Step 3: Add `hook` field to `StageEntry`**

In `StageRegistry.swift`, update `StageEntry`:

```swift
public struct StageEntry: Codable, Sendable, Equatable {
    public var name: String
    public var hook: String?

    public init(name: String, hook: String? = nil) {
        self.name = name
        self.hook = hook
    }
}
```

- [ ] **Step 4: Add `resolvedHook(for:)` to `StageRegistry`**

In `StageRegistry.swift`, add in the `// MARK: - Queries` section after `executionOrder`:

```swift
public func resolvedHook(for stage: String) -> String {
    if let entry = active.first(where: { $0.name == stage }),
       let hook = entry.hook {
        return hook
    }
    return stage
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd piqley-core && swift test --filter StageRegistryTests`
Expected: all tests pass

- [ ] **Step 6: Commit**

Message: `feat(core): add optional hook alias field to StageEntry`

---

### Task 2: Add `stage` field to `HookContext` and update the orchestrator main loop

**Files:**
- Modify: `piqley-cli :: Sources/piqley/Pipeline/PipelineOrchestrator.swift`

- [ ] **Step 1: Add `stage` field to `HookContext`**

In `PipelineOrchestrator.swift`, update the `HookContext` struct (around line 157):

```swift
struct HookContext {
    let pluginIdentifier: String
    let pluginName: String
    let hook: String
    let stage: String
    let temp: TempFolder
    let stateStore: StateStore
    let imageFiles: [URL]
    let dryRun: Bool
    let debug: Bool
    let nonInteractive: Bool
    let skippedImages: Set<String>
    let forkManager: ForkManager
    let executedPlugins: [(hook: String, pluginId: String)]
    let pipelineRunId: String
}
```

- [ ] **Step 2: Update the main loop to resolve the hook and pass both values**

In the `run()` method (around line 108), change:

```swift
for stage in registry.executionOrder {
    guard !pipelineFailed else { break }

    for pluginEntry in pipeline[stage] ?? [] {
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
            forkManager: forkManager,
            executedPlugins: executedPlugins,
            pipelineRunId: pipelineRunId
        )
```

- [ ] **Step 3: Build to check compilation**

Run: `cd piqley-cli && swift build`
Expected: compiles successfully

- [ ] **Step 4: Commit**

Message: `feat: add stage field to HookContext and resolve hook alias in main loop`

---

### Task 3: Update `runPluginHook` to use `ctx.stage` for rule lookup, logs, and caching

**Files:**
- Modify: `piqley-cli :: Sources/piqley/Pipeline/PipelineOrchestrator.swift`

Every `ctx.hook` in `runPluginHook` should become `ctx.stage` except where the hook is passed to the plugin binary (which is in the helpers file, Task 4).

- [ ] **Step 1: Update rule file lookup (line 196)**

Change:
```swift
guard let stageConfig = loadedPlugin.stages[ctx.hook] else {
    logger.debug("[\(loadedPlugin.name)] hook '\(ctx.hook)': no stage file -- skipping")
```
To:
```swift
guard let stageConfig = loadedPlugin.stages[ctx.stage] else {
    logger.debug("[\(loadedPlugin.name)] stage '\(ctx.stage)': no stage file -- skipping")
```

- [ ] **Step 2: Update pre-rules cache key (line 266)**

Change:
```swift
cacheKey: "\(ctx.pluginIdentifier):pre:\(ctx.hook)",
```
To:
```swift
cacheKey: "\(ctx.pluginIdentifier):pre:\(ctx.stage)",
```

- [ ] **Step 3: Update binary log messages (lines 282, 288)**

Change:
```swift
logger.warning("[\(loadedPlugin.name)] hook '\(ctx.hook)': binary command is empty, skipping binary")
```
To:
```swift
logger.warning("[\(loadedPlugin.name)] stage '\(ctx.stage)': binary command is empty, skipping binary")
```

Change:
```swift
logger.info("[\(loadedPlugin.name)] hook '\(ctx.hook)': all images skipped, skipping binary")
```
To:
```swift
logger.info("[\(loadedPlugin.name)] stage '\(ctx.stage)': all images skipped, skipping binary")
```

- [ ] **Step 4: Update post-rules cache key (line 341)**

Change:
```swift
cacheKey: "\(ctx.pluginIdentifier):post:\(ctx.hook)",
```
To:
```swift
cacheKey: "\(ctx.pluginIdentifier):post:\(ctx.stage)",
```

- [ ] **Step 5: Build to check compilation**

Run: `cd piqley-cli && swift build`
Expected: compiles successfully

- [ ] **Step 6: Commit**

Message: `refactor: use ctx.stage for rule lookup, caching, and log messages`

---

### Task 4: Update `runBinary` and result logging to use `ctx.stage` for logs, keep `ctx.hook` for plugin payload

**Files:**
- Modify: `piqley-cli :: Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`

- [ ] **Step 1: Update log message before binary run (line 270)**

Change:
```swift
logger.info("Running plugin '\(loadedPlugin.name)' for hook '\(ctx.hook)'")
```
To:
```swift
logger.info("Running plugin '\(loadedPlugin.name)' for stage '\(ctx.stage)'")
```

Note: line 272 (`hook: ctx.hook`) stays unchanged because this is the hook string sent to the plugin binary.

- [ ] **Step 2: Update result log messages (lines 318, 321, 325)**

Change:
```swift
logger.info("[\(loadedPlugin.name)] hook '\(ctx.hook)': success")
```
To:
```swift
logger.info("[\(loadedPlugin.name)] stage '\(ctx.stage)': success")
```

Change:
```swift
logger.warning("[\(loadedPlugin.name)] hook '\(ctx.hook)': completed with warnings")
```
To:
```swift
logger.warning("[\(loadedPlugin.name)] stage '\(ctx.stage)': completed with warnings")
```

Change:
```swift
"[\(loadedPlugin.name)] hook '\(ctx.hook)': critical failure — aborting pipeline"
```
To:
```swift
"[\(loadedPlugin.name)] stage '\(ctx.stage)': critical failure — aborting pipeline"
```

- [ ] **Step 3: Build to check compilation**

Run: `cd piqley-cli && swift build`
Expected: compiles successfully

- [ ] **Step 4: Commit**

Message: `refactor: use ctx.stage for log messages in runBinary helper`

---

### Task 5: Add integration test for stage hook aliasing

**Files:**
- Modify: `piqley-cli :: Tests/piqleyTests/PipelineOrchestratorTests.swift`

- [ ] **Step 1: Write an integration test that verifies aliased hook is sent to plugin binary**

Add to `PipelineOrchestratorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd piqley-cli && swift test --filter "aliasedStageSendsResolvedHook"`
Expected: PASS

- [ ] **Step 3: Commit**

Message: `test: add integration test for stage hook aliasing`

---

### Task 6: Run full test suite and verify

- [ ] **Step 1: Run piqley-core tests**

Run: `cd piqley-core && swift test`
Expected: all tests pass

- [ ] **Step 2: Run piqley-cli tests**

Run: `cd piqley-cli && swift test`
Expected: all tests pass (the 2 pre-existing SDKVersionResolver failures are known and unrelated)

- [ ] **Step 3: Final commit if any fixups needed**
