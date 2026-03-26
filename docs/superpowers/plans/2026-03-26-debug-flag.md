# Debug Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--debug` boolean flag that flows from CLI through to plugins via JSON payload and environment variable, mirroring `--dry-run`.

**Architecture:** The flag originates as a `@Flag` in `ProcessCommand`, threads through `PipelineOrchestrator.run()` → `HookContext` → `PluginRunner.run()` → `buildEnvironment()` / `buildJSONPayload()`, reaching plugins as `PIQLEY_DEBUG` env var (pipe protocol) or `debug` JSON field (JSON protocol).

**Tech Stack:** Swift, ArgumentParser, PiqleyCore, PiqleyPluginSDK

---

### Task 1: Add `debug` to `PluginInputPayload` (piqley-core)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Payload/PluginInputPayload.swift`

- [ ] **Step 1: Add `debug` property to `PluginInputPayload`**

Add the property after `dryRun`:

```swift
/// Whether debug output is enabled.
public let debug: Bool
```

Add it to the memberwise `init` after the `dryRun` parameter:

```swift
debug: Bool,
```

And assign it:

```swift
self.debug = debug
```

Add it to `init(from decoder:)` after the `dryRun` decode line:

```swift
debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
```

Note: Use `decodeIfPresent` with a default of `false` so existing payloads without `debug` still decode successfully.

- [ ] **Step 2: Verify piqley-core builds**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

Message: `feat: add debug property to PluginInputPayload`

---

### Task 2: Add `PIQLEY_DEBUG` environment constant and thread `debug` through `PluginRunner` (piqley-cli)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Constants/PluginEnvironment.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Plugins/PluginRunner.swift`

- [ ] **Step 1: Add `debug` constant to `PluginEnvironment`**

Add after the `dryRun` line in `PluginEnvironment.swift`:

```swift
static let debug = "PIQLEY_DEBUG"
```

- [ ] **Step 2: Add `debug` parameter to `PluginRunner.run()`**

In `PluginRunner.swift`, add `debug: Bool` parameter after `dryRun: Bool` in the `run()` method signature (line 29):

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
    pipelineRunId: String? = nil
) async throws -> (ExitCodeResult, [String: [String: JSONValue]]?) {
```

- [ ] **Step 3: Pass `debug` through to `BatchRunContext`**

Add `debug: Bool` field to `BatchRunContext` struct and pass it in the `runBatchProxy` call site (around line 54):

```swift
let result = try await runBatchProxy(context: BatchRunContext(
    hook: hook,
    hookConfig: hookConfig,
    batchProxy: batchProxy,
    tempFolder: tempFolder,
    executionLogPath: executionLogPath,
    dryRun: dryRun,
    debug: debug,
    state: state,
    imageFolderOverride: imageFolderOverride,
    pipelineRunId: pipelineRunId
))
```

Update `BatchRunContext` struct to include:

```swift
let debug: Bool
```

- [ ] **Step 4: Pass `debug` to `buildEnvironment()` calls**

Add `debug: Bool` parameter to `buildEnvironment()` after the `dryRun` parameter:

```swift
private func buildEnvironment(
    hook: String,
    folderPath: URL,
    imagePath: URL?,
    executionLogPath: URL,
    dryRun: Bool,
    debug: Bool,
    pipelineRunId: String? = nil
) -> [String: String] {
```

Add to the env dictionary after the `dryRun` entry:

```swift
PluginEnvironment.debug: debug ? "1" : "0",
```

Update ALL call sites of `buildEnvironment()` to pass `debug`:
1. In `run()` around line 68: `debug: debug`
2. In `runBatchProxy()` around line 302: `debug: context.debug`

- [ ] **Step 5: Pass `debug` through to `JSONRunContext` and `buildJSONPayload()`**

Add `debug: Bool` to `JSONRunContext` struct after `dryRun`:

```swift
let debug: Bool
```

Pass it in the `runJSON` call site around line 88:

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
    pipelineRunId: pipelineRunId
))
```

Update `buildJSONPayload()` to accept and pass `debug`:

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
```

Pass `debug: debug` in the `PluginInputPayload(...)` constructor call.

Update the call site in `runJSON()` to pass `debug: context.debug`.

- [ ] **Step 6: Verify it compiles (will fail until orchestrator is updated, which is expected)**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -20`
Expected: Compile errors in PipelineOrchestrator (expected, fixed in Task 3)

- [ ] **Step 7: Commit**

Message: `feat: add PIQLEY_DEBUG env constant and thread debug through PluginRunner`

---

### Task 3: Thread `debug` through `PipelineOrchestrator` and `ProcessCommand` (piqley-cli)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/ProcessCommand.swift`

- [ ] **Step 1: Add `debug` to `PipelineOrchestrator.run()` and `HookContext`**

Add `debug: Bool` parameter to `run()` after `dryRun`:

```swift
func run(sourceURL: URL, dryRun: Bool, debug: Bool, nonInteractive: Bool = false, overwriteSource: Bool = false) async throws -> Bool {
```

Add `debug: Bool` to `HookContext` struct after `dryRun`:

```swift
struct HookContext {
    let pluginIdentifier: String
    let pluginName: String
    let hook: String
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

Pass `debug: debug` in the `HookContext(...)` construction around line 117.

- [ ] **Step 2: Pass `debug` to `PluginRunner.run()` in `runBinary`**

Find where `runner.run(...)` is called in the `runBinary` helper (search for `runner.run(` in the orchestrator file) and add `debug: ctx.debug` after `dryRun: ctx.dryRun`.

- [ ] **Step 3: Add `@Flag` to `ProcessCommand`**

Add after the `dryRun` flag (line 19) in `ProcessCommand.swift`:

```swift
@Flag(help: "Enable debug output from plugins")
var debug = false
```

Update the `orchestrator.run(...)` call to pass `debug: debug`:

```swift
let succeeded = try await orchestrator.run(
    sourceURL: sourceURL, dryRun: dryRun, debug: debug,
    nonInteractive: nonInteractive, overwriteSource: overwriteSource
)
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 5: Run existing tests to confirm nothing is broken**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 6: Commit**

Message: `feat: thread --debug flag through PipelineOrchestrator to plugins`

---

### Task 4: Add `debug` to `PluginRequest` and JSON schema (piqley-plugin-sdk)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Request.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/schemas/plugin-input.schema.json`

- [ ] **Step 1: Add `debug` to `PluginRequest`**

Add the property after `dryRun` (around line 24):

```swift
/// Whether debug output is enabled.
///
/// When `true`, the plugin should emit additional diagnostic information
/// via ``reportProgress(_:)`` to help with troubleshooting.
///
/// For CLI tool plugins using the pipe protocol, this value is passed as
/// the `PIQLEY_DEBUG` environment variable (`"1"` when active, `"0"` otherwise).
///
/// For JSON protocol plugins, this value is the `debug` field in the input payload.
public let debug: Bool
```

Add `self.debug = payload.debug` in the `init(payload:io:registry:)` initializer after the `dryRun` assignment.

Add `debug: Bool = false` parameter to the `mock(...)` factory method, and pass it to both the factory return and the private init.

Add `debug: Bool` to the private `init(...)` used by mock, and assign `self.debug = debug`.

- [ ] **Step 2: Add `debug` to JSON schema**

In `plugin-input.schema.json`, add `"debug"` to the `required` array and add the property:

```json
"debug": { "type": "boolean" },
```

Add after the `"dryRun"` property entry.

- [ ] **Step 3: Build SDK**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 4: Commit**

Message: `feat: add debug property to PluginRequest and JSON schema`

---

### Task 5: Add `Debug.md` documentation (piqley-plugin-sdk)

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/PiqleyPluginSDK.docc/Debug.md`

- [ ] **Step 1: Create `Debug.md`**

```markdown
# Debug Output

Emit extra diagnostic information when piqley runs in debug mode.

## Overview

When a user passes `--debug` to `piqley process`, every plugin in the pipeline receives a debug signal. Your plugin can check this flag and emit additional diagnostic output to help with troubleshooting.

## Checking the Flag

### JSON Protocol (SDK plugins)

The ``PluginRequest/debug`` property is `true` when debug mode is active:

\```swift
func handle(_ request: PluginRequest) async throws -> PluginResponse {
    if request.debug {
        request.reportProgress("[debug] Processing \(imageFiles.count) images")
        request.reportProgress("[debug] Config: \(request.pluginConfig)")
    }
    // ... normal logic
}
\```

### Pipe Protocol (CLI tool plugins)

The `PIQLEY_DEBUG` environment variable is set to `"1"` when active, `"0"` otherwise:

\```bash
if [ "$PIQLEY_DEBUG" = "1" ]; then
    echo "[debug] Image path: $PIQLEY_IMAGE_PATH"
    echo "[debug] Hook: $PIQLEY_HOOK"
fi
\```

### JSON Wire Format

In the JSON input payload sent to plugins over stdin, the field is `debug` (camelCase):

\```json
{
    "hook": "publish",
    "imageFolderPath": "/tmp/piqley-abc123/",
    "dryRun": false,
    "debug": true,
    ...
}
\```

## Implementation Guidelines

- Use ``PluginRequest/reportProgress(_:)`` to emit debug messages.
- Prefix debug messages with `[debug]` for easy filtering.
- Include information useful for troubleshooting: config values, file counts, API request details, timing.
- Debug mode does not change plugin behavior, only verbosity. Unlike dry run, plugins should still perform all normal operations.

## See Also

- ``PluginRequest/debug``
- ``PluginRequest/reportProgress(_:)``
- <doc:DryRun>
```

Note: Remove the backslashes before the triple backticks (they are escape characters for this plan document only).

- [ ] **Step 2: Commit**

Message: `docs: add Debug.md documentation for plugin SDK`

---

### Task 6: Add tests for debug flag plumbing (piqley-cli)

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginRunnerTests.swift`

- [ ] **Step 1: Add test for debug env var in pipe protocol**

Add to the `PluginRunnerTests` suite:

```swift
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
    let (result, _) = try await runner.run(
        hook: "post-publish",
        hookConfig: hookConfig,
        tempFolder: tempFolder,
        executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
        dryRun: false,
        debug: true
    )
    #expect(result == .success)

    let output = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "1")
}
```

- [ ] **Step 2: Add test for debug field in JSON payload**

Add to the `PluginRunnerTests` suite:

```swift
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
    let (result, _) = try await runner.run(
        hook: "publish",
        hookConfig: hookConfig,
        tempFolder: tempFolder,
        executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
        dryRun: false,
        debug: true
    )
    #expect(result == .success)

    let output = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "True")
}
```

- [ ] **Step 3: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 4: Commit**

Message: `test: add tests for debug flag plumbing through PluginRunner`
