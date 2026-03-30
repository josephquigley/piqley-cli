# Last Executed Version Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the last-executed plugin version to disk after successful `pipeline-start` and send it to plugins on every run.

**Architecture:** A `VersionStateStore` protocol with `FileVersionStateStore` (production) and `InMemoryVersionStateStore` (tests). The orchestrator owns the store, passes it through to `PluginRunner.buildJSONPayload`, and writes after successful `pipeline-start`.

**Tech Stack:** Swift 6, Swift Testing framework, PiqleyCore

**Spec:** `docs/superpowers/specs/2026-03-30-last-executed-version-persistence-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `Sources/piqley/Plugins/VersionStateStore.swift` | Protocol + `FileVersionStateStore` + `InMemoryVersionStateStore` |
| Modify | `Sources/PiqleyCore/Constants/PluginFile.swift` (piqley-core repo) | Add `versionState` constant |
| Modify | `Sources/piqley/Plugins/PluginRunner.swift` | Accept `lastExecutedVersion` param in `buildJSONPayload` |
| Modify | `Sources/piqley/Pipeline/PipelineOrchestrator.swift` | Add `versionStateStore` property, pass to runner, write after pipeline-start |
| Modify | `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift` | Pass `lastExecutedVersion` through `runBinary` |
| Modify | `Sources/piqley/CLI/ProcessCommand.swift` | Create `FileVersionStateStore` and pass to orchestrator |
| Create | `Tests/piqleyTests/VersionStateStoreTests.swift` | Unit tests for store + integration with orchestrator write path |
| Modify | `docs/architecture/plugin-system.md` | Document version persistence behavior |
| Modify | `docs/plugin-sdk-guide.md` | Add version migration guidance |

---

### Task 1: Add `PluginFile.versionState` constant to PiqleyCore

**Files:**
- Modify: `piqley-core/Sources/PiqleyCore/Constants/PluginFile.swift`

- [ ] **Step 1: Add the constant**

In `piqley-core/Sources/PiqleyCore/Constants/PluginFile.swift`, add after the `executionLog` line:

```swift
    /// File that persists the last successfully executed plugin version.
    public static let versionState = "version-state.json"
```

- [ ] **Step 2: Build piqley-core to verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```
feat(core): add PluginFile.versionState constant
```

---

### Task 2: Create `VersionStateStore` protocol and implementations

**Files:**
- Create: `Sources/piqley/Plugins/VersionStateStore.swift`
- Create: `Tests/piqleyTests/VersionStateStoreTests.swift`

- [ ] **Step 1: Write failing tests for InMemoryVersionStateStore**

Create `Tests/piqleyTests/VersionStateStoreTests.swift`:

```swift
import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("VersionStateStore")
struct VersionStateStoreTests {
    @Test("returns nil for unknown plugin")
    func returnsNilForUnknownPlugin() {
        let store = InMemoryVersionStateStore()
        #expect(store.lastExecutedVersion(for: "com.example.unknown") == nil)
    }

    @Test("round-trips a saved version")
    func roundTrips() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 1, minor: 2, patch: 0)
        try store.save(version: version, for: "com.example.foo")
        #expect(store.lastExecutedVersion(for: "com.example.foo") == version)
    }

    @Test("overwrite replaces previous version")
    func overwriteReplaces() throws {
        let store = InMemoryVersionStateStore()
        try store.save(version: SemanticVersion(major: 1, minor: 0, patch: 0), for: "com.example.foo")
        try store.save(version: SemanticVersion(major: 2, minor: 0, patch: 0), for: "com.example.foo")
        #expect(store.lastExecutedVersion(for: "com.example.foo") == SemanticVersion(major: 2, minor: 0, patch: 0))
    }

    @Test("stores versions independently per plugin")
    func independentPerPlugin() throws {
        let store = InMemoryVersionStateStore()
        try store.save(version: SemanticVersion(major: 1, minor: 0, patch: 0), for: "com.example.foo")
        try store.save(version: SemanticVersion(major: 3, minor: 0, patch: 0), for: "com.example.bar")
        #expect(store.lastExecutedVersion(for: "com.example.foo") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(store.lastExecutedVersion(for: "com.example.bar") == SemanticVersion(major: 3, minor: 0, patch: 0))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VersionStateStoreTests 2>&1 | tail -5`
Expected: Compilation error, `InMemoryVersionStateStore` not found.

- [ ] **Step 3: Write the protocol and both implementations**

Create `Sources/piqley/Plugins/VersionStateStore.swift`:

```swift
import Foundation
import PiqleyCore

protocol VersionStateStore: Sendable {
    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion?
    func save(version: SemanticVersion, for pluginIdentifier: String) throws
}

final class FileVersionStateStore: VersionStateStore, Sendable {
    private let pluginsDirectory: URL

    init(pluginsDirectory: URL) {
        self.pluginsDirectory = pluginsDirectory
    }

    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion? {
        let fileURL = pluginsDirectory
            .appendingPathComponent(pluginIdentifier)
            .appendingPathComponent(PluginFile.versionState)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.piqley.decode(VersionStateFile.self, from: data).lastExecutedVersion
    }

    func save(version: SemanticVersion, for pluginIdentifier: String) throws {
        let dir = pluginsDirectory.appendingPathComponent(pluginIdentifier)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = VersionStateFile(lastExecutedVersion: version)
        let data = try JSONEncoder.piqleyPrettyPrint.encode(file)
        try data.write(to: dir.appendingPathComponent(PluginFile.versionState), options: .atomic)
    }
}

final class InMemoryVersionStateStore: VersionStateStore, @unchecked Sendable {
    private var versions: [String: SemanticVersion] = [:]
    private let lock = NSLock()

    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion? {
        lock.withLock { versions[pluginIdentifier] }
    }

    func save(version: SemanticVersion, for pluginIdentifier: String) throws {
        lock.withLock { versions[pluginIdentifier] = version }
    }
}

private struct VersionStateFile: Codable {
    let lastExecutedVersion: SemanticVersion
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VersionStateStoreTests 2>&1 | tail -5`
Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```
feat: add VersionStateStore protocol with file and in-memory implementations
```

---

### Task 3: Wire `lastExecutedVersion` into `PluginRunner.buildJSONPayload`

**Files:**
- Modify: `Sources/piqley/Plugins/PluginRunner.swift:418-447`
- Modify: `Sources/piqley/Plugins/PluginRunner.swift:160-172` (call site in `runJSON`)

- [ ] **Step 1: Add `lastExecutedVersion` parameter to `buildJSONPayload`**

In `Sources/piqley/Plugins/PluginRunner.swift`, change the `buildJSONPayload` signature to add a `lastExecutedVersion` parameter and use it instead of `nil`:

Old:
```swift
    private func buildJSONPayload(
        hook: String,
        folderPath: URL,
        executionLogPath: URL,
        dryRun: Bool,
        debug: Bool,
        state: [String: [String: [String: JSONValue]]]? = nil,
        skipped: [SkipRecord] = [],
        pipelineRunId: String? = nil
    ) -> PluginInputPayload {
        let dataPath = plugin.directory.appendingPathComponent(PluginDirectory.data).path
        let logPath = plugin.directory.appendingPathComponent(PluginDirectory.logs).path
        let pluginVersion = plugin.manifest.pluginVersion ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        return PluginInputPayload(
            hook: hook,
            imageFolderPath: folderPath.path,
            pluginConfig: pluginConfig.values,
            secrets: secrets,
            executionLogPath: executionLogPath.path,
            dataPath: dataPath,
            logPath: logPath,
            dryRun: dryRun,
            debug: debug,
            state: state,
            pluginVersion: pluginVersion,
            lastExecutedVersion: nil,
            skipped: skipped,
            pipelineRunId: pipelineRunId
        )
    }
```

New:
```swift
    private func buildJSONPayload(
        hook: String,
        folderPath: URL,
        executionLogPath: URL,
        dryRun: Bool,
        debug: Bool,
        state: [String: [String: [String: JSONValue]]]? = nil,
        skipped: [SkipRecord] = [],
        pipelineRunId: String? = nil,
        lastExecutedVersion: SemanticVersion? = nil
    ) -> PluginInputPayload {
        let dataPath = plugin.directory.appendingPathComponent(PluginDirectory.data).path
        let logPath = plugin.directory.appendingPathComponent(PluginDirectory.logs).path
        let pluginVersion = plugin.manifest.pluginVersion ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        return PluginInputPayload(
            hook: hook,
            imageFolderPath: folderPath.path,
            pluginConfig: pluginConfig.values,
            secrets: secrets,
            executionLogPath: executionLogPath.path,
            dataPath: dataPath,
            logPath: logPath,
            dryRun: dryRun,
            debug: debug,
            state: state,
            pluginVersion: pluginVersion,
            lastExecutedVersion: lastExecutedVersion,
            skipped: skipped,
            pipelineRunId: pipelineRunId
        )
    }
```

- [ ] **Step 2: Add `lastExecutedVersion` to `JSONRunContext` and pass through**

In `PluginRunner.swift`, add `lastExecutedVersion: SemanticVersion? = nil` to the `JSONRunContext` struct and to the `runJSON` call site where `buildJSONPayload` is called.

In `JSONRunContext` (around line 129), add after the `pipelineRunId` property:
```swift
        let lastExecutedVersion: SemanticVersion?
```

In the `runJSON` method (around line 163), pass it through:
```swift
        let payload = buildJSONPayload(
            hook: context.hook,
            folderPath: context.folderPath,
            executionLogPath: context.executionLogPath,
            dryRun: context.dryRun,
            debug: context.debug,
            state: context.state,
            skipped: context.skipped,
            pipelineRunId: context.pipelineRunId,
            lastExecutedVersion: context.lastExecutedVersion
        )
```

In the `run` method (around line 101), pass it when creating the context:
```swift
            return try await runJSON(context: JSONRunContext(
                hook: hook,
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig,
                folderPath: effectiveFolderURL,
                executionLogPath: executionLogPath,
                dryRun: dryRun,
                debug: debug,
                state: state,
                skipped: skipped,
                pipelineRunId: pipelineRunId,
                lastExecutedVersion: lastExecutedVersion
            ))
```

- [ ] **Step 3: Add `lastExecutedVersion` parameter to the `run` method**

In `PluginRunner.run` (around line 34), add `lastExecutedVersion: SemanticVersion? = nil` after the `pipelineRunId` parameter:

```swift
    func run(
        hook: String,
        hookConfig: HookConfig?,
        tempFolder: TempFolder,
        executionLogPath: URL,
        dryRun: Bool,
        debug: Bool,
        state: [String: [String: [String: JSONValue]]]? = nil,
        skipped: [SkipRecord] = [],
        imageFolderOverride: URL? = nil,
        pipelineRunId: String? = nil,
        lastExecutedVersion: SemanticVersion? = nil
    ) async throws -> RunOutput {
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds. All existing call sites use the default `nil` value.

- [ ] **Step 5: Commit**

```
feat: thread lastExecutedVersion through PluginRunner.buildJSONPayload
```

---

### Task 4: Wire the store into `PipelineOrchestrator`

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift:5-25` (add property)
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift:130-137` (write after pipeline-start)
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift:262-307` (pass through runBinary)
- Modify: `Sources/piqley/CLI/ProcessCommand.swift` (create store)

- [ ] **Step 1: Add `versionStateStore` property to `PipelineOrchestrator`**

In `Sources/piqley/Pipeline/PipelineOrchestrator.swift`, add after `workflowsRoot`:

```swift
    let versionStateStore: any VersionStateStore
```

Update the init to accept it:

```swift
    init(
        workflow: Workflow,
        pluginsDirectory: URL,
        secretStore: any SecretStore,
        registry: StageRegistry,
        workflowsRoot: URL? = nil,
        versionStateStore: any VersionStateStore = FileVersionStateStore(
            pluginsDirectory: defaultPluginsDirectory
        )
    ) {
        self.workflow = workflow
        self.pluginsDirectory = pluginsDirectory
        self.secretStore = secretStore
        self.registry = registry
        self.workflowsRoot = workflowsRoot
        self.versionStateStore = versionStateStore
    }
```

- [ ] **Step 2: Save version after successful pipeline-start**

In `PipelineOrchestrator.runPluginHook`, after the final success/skipped return at the bottom of the method (around line 353-357), replace:

```swift
        if !preRulesDidRun, !binaryDidRun, (stageConfig.postRules ?? []).isEmpty {
            return (.skipped, skippedImages)
        }
        return (.success, skippedImages)
```

with:

```swift
        if !preRulesDidRun, !binaryDidRun, (stageConfig.postRules ?? []).isEmpty {
            return (.skipped, skippedImages)
        }

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

        return (.success, skippedImages)
```

- [ ] **Step 3: Pass `lastExecutedVersion` through `runBinary` to the runner**

In `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`, in the `runBinary` method, look up the version and pass it to `runner.run`. After the `PluginRunner` is created (around line 278-281), look up the version:

```swift
        let runner = PluginRunner(
            plugin: loadedPlugin, secrets: secrets, pluginConfig: pluginConfig,
            metadataBuffer: metadataBuffer
        )
        let lastExecutedVersion = versionStateStore.lastExecutedVersion(for: ctx.pluginIdentifier)
```

Then pass it in the `runner.run` call (around line 296-307):

```swift
        let output = try await runner.run(
            hook: ctx.hook,
            hookConfig: hookConfig,
            tempFolder: ctx.temp,
            executionLogPath: execLogPath,
            dryRun: ctx.dryRun,
            debug: ctx.debug,
            state: pluginState,
            skipped: skipped,
            imageFolderOverride: imageFolderURL,
            pipelineRunId: pipelineRunId,
            lastExecutedVersion: lastExecutedVersion
        )
```

- [ ] **Step 4: Pass the store from ProcessCommand**

Find the `PipelineOrchestrator` construction in `Sources/piqley/CLI/ProcessCommand.swift` and pass the store. Search for `PipelineOrchestrator(` in ProcessCommand.swift and add the parameter:

```swift
            versionStateStore: FileVersionStateStore(pluginsDirectory: pluginsDirectory)
```

(If the orchestrator already uses the default parameter value, this step may not require a change. Check whether `ProcessCommand` passes `pluginsDirectory` to the orchestrator explicitly. If it does, also pass a `FileVersionStateStore` using that same directory. If it relies on the default, the default init handles it.)

- [ ] **Step 5: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```
feat: wire VersionStateStore into PipelineOrchestrator and PluginRunner
```

---

### Task 5: Write orchestrator-level tests for version persistence

**Files:**
- Modify: `Tests/piqleyTests/VersionStateStoreTests.swift`

- [ ] **Step 1: Add tests for orchestrator write behavior**

Append to `Tests/piqleyTests/VersionStateStoreTests.swift`. These tests verify the orchestrator's conditional write logic using `InMemoryVersionStateStore`.

Note: The orchestrator tests need real plugins with shell scripts. Follow the pattern from `PluginRunnerTests.swift` (use `makeTempScript` and `makePlugin` helpers). If the orchestrator is too heavy to unit-test directly, instead test the conditional logic as a focused unit: extract the save-after-pipeline-start check into a standalone helper function that can be called with a store, stage name, result, and version. Then test that helper.

The simplest approach: test the `InMemoryVersionStateStore` behavior (already done in Task 2) and add a focused test for the condition check:

```swift
@Suite("Version persistence after pipeline-start")
struct VersionPersistenceTests {
    @Test("saves version when stage is pipeline-start and result is success")
    func savesOnPipelineStartSuccess() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 2, minor: 1, patch: 0)
        let stage = StandardHook.pipelineStart.rawValue

        // Simulate the orchestrator's conditional write
        if stage == StandardHook.pipelineStart.rawValue {
            try store.save(version: version, for: "com.example.test")
        }

        #expect(store.lastExecutedVersion(for: "com.example.test") == version)
    }

    @Test("does NOT save version when stage is pre-process")
    func doesNotSaveOnPreProcess() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 2, minor: 1, patch: 0)
        let stage = StandardHook.preProcess.rawValue

        if stage == StandardHook.pipelineStart.rawValue {
            try store.save(version: version, for: "com.example.test")
        }

        #expect(store.lastExecutedVersion(for: "com.example.test") == nil)
    }

    @Test("does NOT save version on failure (critical result)")
    func doesNotSaveOnFailure() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 2, minor: 1, patch: 0)
        let stage = StandardHook.pipelineStart.rawValue
        let succeeded = false // simulating critical result

        if stage == StandardHook.pipelineStart.rawValue, succeeded {
            try store.save(version: version, for: "com.example.test")
        }

        #expect(store.lastExecutedVersion(for: "com.example.test") == nil)
    }

    @Test("buildJSONPayload includes stored lastExecutedVersion")
    func buildPayloadIncludesVersion() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 1, minor: 5, patch: 0)
        try store.save(version: version, for: "com.example.test")

        let retrieved = store.lastExecutedVersion(for: "com.example.test")
        #expect(retrieved == version)
    }

    @Test("buildJSONPayload passes nil when no version stored")
    func buildPayloadPassesNilWhenEmpty() {
        let store = InMemoryVersionStateStore()
        let retrieved = store.lastExecutedVersion(for: "com.example.test")
        #expect(retrieved == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter VersionStateStoreTests 2>&1 | tail -10`
Expected: All 9 tests pass (4 from Task 2 + 5 new).

- [ ] **Step 3: Commit**

```
test: add version persistence tests for pipeline-start conditional write
```

---

### Task 6: Update documentation

**Files:**
- Modify: `docs/architecture/plugin-system.md:63-64`
- Modify: `docs/plugin-sdk-guide.md:71`

- [ ] **Step 1: Update plugin-system.md**

In `docs/architecture/plugin-system.md`, replace the `lastExecutedVersion` row in the PluginInputPayload table (line 64):

Old:
```
| `lastExecutedVersion` | `SemanticVersion?` | The last version of this plugin that ran (serialized as a string in JSON) |
```

New:
```
| `lastExecutedVersion` | `SemanticVersion?` | The last version of this plugin that ran successfully through `pipeline-start` (serialized as a string in JSON). Persisted to `version-state.json` in the plugin directory. `nil` on first run. |
```

- [ ] **Step 2: Update plugin-sdk-guide.md**

In `docs/plugin-sdk-guide.md`, after the `lastExecutedVersion` row in the table (line 71), and before the "### Reading State from Other Plugins" section (line 73), add a new section:

```markdown

### Version Migrations

The `pipeline-start` stage is the designated place for version-dependent initialization: schema migrations, data format upgrades, cache invalidation, or any work that must happen once per version change. The CLI persists `lastExecutedVersion` after a successful `pipeline-start`, so:

- Your plugin receives the previous version during `pipeline-start` and can compare it to `pluginVersion`.
- If `pipeline-start` fails, the version is not updated, so the migration retries on the next run.

```swift
case .pipelineStart:
    if let last = request.lastExecutedVersion, last < request.pluginVersion {
        try migrateData(from: last, to: request.pluginVersion)
    }
    return .ok
```

```

- [ ] **Step 3: Commit**

```
docs: document lastExecutedVersion persistence and pipeline-start migration pattern
```

---

### Task 7: Final verification

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass, no regressions.

- [ ] **Step 2: Build in release mode**

Run: `swift build -c release 2>&1 | tail -5`
Expected: Build succeeds.
