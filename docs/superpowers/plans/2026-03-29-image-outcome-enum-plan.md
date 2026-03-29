# Image Outcome Enum Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `success: Bool` on image results with a four-state `ImageOutcome` enum (`success`, `failure`, `warning`, `skip`) across piqley-core, piqley-plugin-sdk, and piqley-cli.

**Architecture:** Add `ImageOutcome` enum to PiqleyCore. Add a `status: ImageOutcome?` field to `PluginOutputLine` (keeping `success: Bool?` for `result` lines). Update the SDK's `reportImageResult` to accept `outcome: ImageOutcome`. Update the CLI's `PluginRunner` to read the new `status` field and create `SkipRecord`s for skip outcomes.

**Tech Stack:** Swift, Swift Testing, PiqleyCore SPM package, PiqleyPluginSDK SPM package

---

## File Map

### piqley-core
- Create: `Sources/PiqleyCore/Payload/ImageOutcome.swift`
- Modify: `Sources/PiqleyCore/Payload/PluginOutputLine.swift`
- Modify: `Tests/PiqleyCoreTests/PayloadCodingTests.swift`

### piqley-plugin-sdk
- Modify: `swift/PiqleyPluginSDK/Request.swift`
- Modify: `swift/Tests/RequestTests.swift`
- Modify: `swift/Tests/MockTests.swift`
- Modify: `schemas/plugin-output.schema.json`

### piqley-cli
- Modify: `Sources/piqley/Plugins/PluginRunner.swift`
- Modify: `Tests/piqleyTests/PluginRunnerTests.swift`

---

### Task 1: Add ImageOutcome enum to PiqleyCore

**Files:**
- Create: `Sources/PiqleyCore/Payload/ImageOutcome.swift` (in piqley-core repo)

- [ ] **Step 1: Create the ImageOutcome enum**

```swift
/// The outcome of processing a single image in a plugin.
public enum ImageOutcome: String, Codable, Sendable, Equatable {
    case success
    case failure
    case warning
    case skip
}
```

Write this to `Sources/PiqleyCore/Payload/ImageOutcome.swift` in the piqley-core repo.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```
feat: add ImageOutcome enum for image result status
```

---

### Task 2: Add status field to PluginOutputLine

**Files:**
- Modify: `Sources/PiqleyCore/Payload/PluginOutputLine.swift` (in piqley-core repo)
- Modify: `Tests/PiqleyCoreTests/PayloadCodingTests.swift`

- [ ] **Step 1: Write failing tests for the new status field**

In `Tests/PiqleyCoreTests/PayloadCodingTests.swift`, replace the two existing imageResult tests with four new ones:

Replace `decodeOutputLineImageResult`:
```swift
@Test func decodeOutputLineImageResultSuccess() throws {
    let json = #"{"type": "imageResult", "filename": "photo.jpg", "status": "success"}"#
    let line = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: Data(json.utf8))
    #expect(line.type == "imageResult")
    #expect(line.filename == "photo.jpg")
    #expect(line.status == .success)
}
```

Replace `decodeOutputLineImageResultWithError`:
```swift
@Test func decodeOutputLineImageResultFailure() throws {
    let json = #"{"type": "imageResult", "filename": "bad.jpg", "status": "failure", "error": "File not found"}"#
    let line = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: Data(json.utf8))
    #expect(line.type == "imageResult")
    #expect(line.filename == "bad.jpg")
    #expect(line.status == .failure)
    #expect(line.error == "File not found")
}
```

Add two new tests:
```swift
@Test func decodeOutputLineImageResultWarning() throws {
    let json = #"{"type": "imageResult", "filename": "dim.jpg", "status": "warning", "error": "low resolution"}"#
    let line = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: Data(json.utf8))
    #expect(line.type == "imageResult")
    #expect(line.filename == "dim.jpg")
    #expect(line.status == .warning)
    #expect(line.error == "low resolution")
}

@Test func decodeOutputLineImageResultSkip() throws {
    let json = #"{"type": "imageResult", "filename": "raw.cr3", "status": "skip", "error": "not a supported format"}"#
    let line = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: Data(json.utf8))
    #expect(line.type == "imageResult")
    #expect(line.filename == "raw.cr3")
    #expect(line.status == .skip)
    #expect(line.error == "not a supported format")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -10`
Expected: Compilation error, `PluginOutputLine` has no member `status`

- [ ] **Step 3: Add status field to PluginOutputLine**

In `Sources/PiqleyCore/Payload/PluginOutputLine.swift`, add a `status` property and update the init:

```swift
/// A single line of output from a piqley plugin, streamed as newline-delimited JSON.
public struct PluginOutputLine: Codable, Sendable, Equatable {
    /// The type of output line (e.g. "result", "progress", "imageResult").
    public let type: String
    /// A human-readable message.
    public let message: String?
    /// The filename associated with this output (for image results).
    public let filename: String?
    /// Whether the operation succeeded (used by "result" lines).
    public let success: Bool?
    /// The outcome of processing this image (used by "imageResult" lines).
    public let status: ImageOutcome?
    /// An error message if the operation failed.
    public let error: String?
    /// State to persist, keyed by folder path then key.
    public let state: [String: [String: JSONValue]]?

    public init(
        type: String,
        message: String? = nil,
        filename: String? = nil,
        success: Bool? = nil,
        status: ImageOutcome? = nil,
        error: String? = nil,
        state: [String: [String: JSONValue]]? = nil
    ) {
        self.type = type
        self.message = message
        self.filename = filename
        self.success = success
        self.status = status
        self.error = error
        self.state = state
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```
feat: add status field to PluginOutputLine for image outcomes
```

---

### Task 3: Update SDK reportImageResult and test support types

**Files:**
- Modify: `swift/PiqleyPluginSDK/Request.swift` (in piqley-plugin-sdk repo)
- Modify: `swift/Tests/RequestTests.swift`
- Modify: `swift/Tests/MockTests.swift`

- [ ] **Step 1: Update the piqley-core dependency**

The piqley-plugin-sdk depends on piqley-core via a local path or branch. Ensure the SDK's `Package.swift` points to the updated piqley-core (with the new `ImageOutcome` enum and `status` field). If it uses a branch dependency, the worktree branch for piqley-core must be pushed or the path dependency updated.

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && cat Package.swift | grep -A2 piqley-core`

Adjust the dependency to point to the updated piqley-core if needed.

- [ ] **Step 2: Write failing tests for the new API**

In `swift/Tests/RequestTests.swift`, replace the two `reportImageResult` tests:

Replace `reportImageResultSuccessWritesJSONLine`:
```swift
@Test func reportImageResultSuccessWritesJSONLine() throws {
    let io = CapturedIO()
    let req = try PluginRequest(payload: makePayload(), io: io, registry: standardRegistry)
    req.reportImageResult("photo.jpg", outcome: .success)
    #expect(io.lines.count == 1)
    let decoded = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: io.lines[0].data(using: .utf8)!)
    #expect(decoded.type == "imageResult")
    #expect(decoded.filename == "photo.jpg")
    #expect(decoded.status == .success)
    #expect(decoded.error == nil)
}
```

Replace `reportImageResultFailureWritesJSONLine`:
```swift
@Test func reportImageResultFailureWritesJSONLine() throws {
    let io = CapturedIO()
    let req = try PluginRequest(payload: makePayload(), io: io, registry: standardRegistry)
    req.reportImageResult("photo.jpg", outcome: .failure, message: "conversion failed")
    #expect(io.lines.count == 1)
    let decoded = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: io.lines[0].data(using: .utf8)!)
    #expect(decoded.type == "imageResult")
    #expect(decoded.filename == "photo.jpg")
    #expect(decoded.status == .failure)
    #expect(decoded.error == "conversion failed")
}
```

Add tests for warning and skip:
```swift
@Test func reportImageResultWarningWritesJSONLine() throws {
    let io = CapturedIO()
    let req = try PluginRequest(payload: makePayload(), io: io, registry: standardRegistry)
    req.reportImageResult("photo.jpg", outcome: .warning, message: "missing GPS data")
    #expect(io.lines.count == 1)
    let decoded = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: io.lines[0].data(using: .utf8)!)
    #expect(decoded.type == "imageResult")
    #expect(decoded.filename == "photo.jpg")
    #expect(decoded.status == .warning)
    #expect(decoded.error == "missing GPS data")
}

@Test func reportImageResultSkipWritesJSONLine() throws {
    let io = CapturedIO()
    let req = try PluginRequest(payload: makePayload(), io: io, registry: standardRegistry)
    req.reportImageResult("photo.jpg", outcome: .skip, message: "not a RAW file")
    #expect(io.lines.count == 1)
    let decoded = try JSONDecoder.piqley.decode(PluginOutputLine.self, from: io.lines[0].data(using: .utf8)!)
    #expect(decoded.type == "imageResult")
    #expect(decoded.filename == "photo.jpg")
    #expect(decoded.status == .skip)
    #expect(decoded.error == "not a RAW file")
}
```

In `swift/Tests/MockTests.swift`, update the captured output tests:

Replace `capturedOutputImageResultSuccess`:
```swift
@Test func capturedOutputImageResultSuccess() {
    let (req, output) = PluginRequest.mock()
    req.reportImageResult("a.jpg", outcome: .success)
    #expect(output.imageResults.count == 1)
    #expect(output.imageResults[0].filename == "a.jpg")
    #expect(output.imageResults[0].outcome == .success)
    #expect(output.imageResults[0].error == nil)
}
```

Replace `capturedOutputImageResultFailure`:
```swift
@Test func capturedOutputImageResultFailure() {
    let (req, output) = PluginRequest.mock()
    req.reportImageResult("b.jxl", outcome: .failure, message: "unsupported codec")
    #expect(output.imageResults.count == 1)
    #expect(output.imageResults[0].filename == "b.jxl")
    #expect(output.imageResults[0].outcome == .failure)
    #expect(output.imageResults[0].error == "unsupported codec")
}
```

Replace `capturedOutputMixedLines`:
```swift
@Test func capturedOutputMixedLines() {
    let (req, output) = PluginRequest.mock()
    req.reportProgress("Starting")
    req.reportImageResult("c.jpg", outcome: .success)
    req.reportImageResult("d.jpg", outcome: .failure, message: "err")
    req.reportProgress("Done")

    #expect(output.progressMessages == ["Starting", "Done"])
    #expect(output.imageResults.count == 2)
    #expect(output.allLines.count == 4)
}
```

Replace `capturedOutputAllLines`:
```swift
@Test func capturedOutputAllLines() {
    let (req, output) = PluginRequest.mock()
    req.reportProgress("hello")
    req.reportImageResult("x.jpg", outcome: .success)
    #expect(output.allLines.count == 2)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -10`
Expected: Compilation errors, no `outcome:` parameter on `reportImageResult`

- [ ] **Step 4: Update reportImageResult implementation**

In `swift/PiqleyPluginSDK/Request.swift`, replace the `reportImageResult` method (lines 83-89):

```swift
/// Writes an imageResult line to stdout immediately.
public func reportImageResult(_ filename: String, outcome: ImageOutcome, message: String? = nil) {
    let line = PluginOutputLine(type: "imageResult", filename: filename, status: outcome, error: message)
    if let data = try? JSONEncoder.piqley.encode(line), let string = String(data: data, encoding: .utf8) {
        io.writeLine(string)
    }
}
```

- [ ] **Step 5: Update ImageResult struct**

In `swift/PiqleyPluginSDK/Request.swift`, replace the `ImageResult` struct (lines 95-99):

```swift
/// Result of a captured image result report.
public struct ImageResult: Sendable {
    public let filename: String
    public let outcome: ImageOutcome
    public let error: String?
}
```

- [ ] **Step 6: Update CapturedOutput.imageResults**

In `swift/PiqleyPluginSDK/Request.swift`, replace the `imageResults` computed property in `CapturedOutput` (lines 118-129):

```swift
public var imageResults: [ImageResult] {
    io.lines.compactMap { line -> ImageResult? in
        guard
            let data = line.data(using: .utf8),
            let decoded = try? JSONDecoder.piqley.decode(PluginOutputLine.self, from: data),
            decoded.type == "imageResult",
            let filename = decoded.filename,
            let status = decoded.status
        else { return nil }
        return ImageResult(filename: filename, outcome: status, error: decoded.error)
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 8: Commit**

```
feat: replace boolean success with ImageOutcome enum in reportImageResult
```

---

### Task 4: Update JSON schema

**Files:**
- Modify: `schemas/plugin-output.schema.json` (in piqley-plugin-sdk repo)

- [ ] **Step 1: Update the imageResult schema**

Replace the full contents of `schemas/plugin-output.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://piqley.dev/schemas/plugin-output.schema.json",
  "title": "Piqley Plugin Output Line",
  "type": "object",
  "required": ["type"],
  "oneOf": [
    {
      "properties": {
        "type": { "const": "progress" },
        "message": { "type": "string" }
      },
      "required": ["type", "message"]
    },
    {
      "properties": {
        "type": { "const": "imageResult" },
        "filename": { "type": "string" },
        "status": { "type": "string", "enum": ["success", "failure", "warning", "skip"] },
        "error": { "type": ["string", "null"] }
      },
      "required": ["type", "filename", "status"]
    },
    {
      "properties": {
        "type": { "const": "result" },
        "success": { "type": "boolean" },
        "error": { "type": ["string", "null"] },
        "message": { "type": ["string", "null"] },
        "state": {
          "type": "object",
          "additionalProperties": {
            "type": "object",
            "additionalProperties": true
          }
        }
      },
      "required": ["type", "success"]
    }
  ]
}
```

- [ ] **Step 2: Commit**

```
docs: update plugin output schema with ImageOutcome status field
```

---

### Task 5: Update CLI PluginRunner to read status field

**Files:**
- Modify: `Sources/piqley/Plugins/PluginRunner.swift` (in piqley-cli repo)
- Modify: `Tests/piqleyTests/PluginRunnerTests.swift`

- [ ] **Step 1: Update the piqley-core dependency**

Ensure the CLI's `Package.swift` points to the updated piqley-core. Check the current dependency:

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && cat Package.swift | grep -A2 piqley-core`

Adjust if needed to pick up the `ImageOutcome` and `status` changes.

- [ ] **Step 2: Write a failing test for imageResult with status**

In `Tests/piqleyTests/PluginRunnerTests.swift`, add a test that emits the new `status` field format:

```swift
@Test("json protocol: imageResult with status field is parsed")
func testJSONImageResultStatus() async throws {
    let script = try makeTempScript("""
    printf '{"type":"imageResult","filename":"photo.jpg","status":"warning","error":"low res"}\\n'
    printf '{"type":"imageResult","filename":"skip.jpg","status":"skip","error":"not RAW"}\\n'
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
```

- [ ] **Step 3: Run the test to verify it passes (baseline)**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter testJSONImageResultStatus 2>&1 | tail -10`
Expected: PASS (the current code just logs and ignores imageResult lines, so the new format won't break anything as long as it decodes)

- [ ] **Step 4: Update the imageResult case in readJSONOutput**

In `Sources/piqley/Plugins/PluginRunner.swift`, replace the `"imageResult"` case (lines 234-237):

```swift
case "imageResult":
    logger.debug(
        "[\(plugin.name)] imageResult: \(obj.filename ?? "") status=\(obj.status?.rawValue ?? "unknown")"
    )
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 6: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 7: Commit**

```
feat: read ImageOutcome status field in PluginRunner
```

---

### Task 6: Create SkipRecords from skip outcomes

**Files:**
- Modify: `Sources/piqley/Plugins/PluginRunner.swift` (in piqley-cli repo)
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift`

- [ ] **Step 1: Add skippedImages to RunOutput**

In `Sources/piqley/Plugins/PluginRunner.swift`, the `RunOutput` struct at line 23 currently has three fields. Add `skippedImages`:

```swift
/// Result of running a plugin hook.
struct RunOutput {
    let exitResult: ExitCodeResult
    let state: [String: [String: JSONValue]]?
    let errorMessage: String?
    let skippedImages: [String]
}
```

- [ ] **Step 2: Update all RunOutput return sites**

There are multiple places that return `RunOutput`. Update each one to include `skippedImages: []`:

In `readJSONOutput` (around line 256, the "no result line" case):
```swift
return RunOutput(exitResult: .critical, state: nil, errorMessage: nil, skippedImages: [])
```

In `readJSONOutput` (around line 259, the normal return):
```swift
return RunOutput(
    exitResult: evaluator.evaluate(process.terminationStatus),
    state: resultState,
    errorMessage: resultError,
    skippedImages: skippedFilenames
)
```

Search for all other `RunOutput(` calls in the file (pipe protocol path, timeout paths, etc.) and add `skippedImages: []` to each.

- [ ] **Step 3: Collect skipped filenames in readJSONOutput**

In the `readJSONOutput` method, add `var skippedFilenames: [String] = []` alongside the existing tracking vars (`gotResult`, `resultState`, `resultError`) near line 196.

In the `"imageResult"` case (after the existing debug log), add:

```swift
if obj.status == .skip, let filename = obj.filename {
    skippedFilenames.append(filename)
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeded (may require fixing additional `RunOutput` call sites found during compilation)

- [ ] **Step 5: Propagate skip records in PipelineOrchestrator+Helpers.swift**

In `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`, the `runBinary` method consumes the `RunOutput` at line 271. After line 282 (`let output = try await runner.run(...)`) and before line 283 (`let result = output.exitResult`), add code to create skip records and return them:

The `runBinary` method currently returns `HookResult`. Change it to return `(HookResult, [String])` where the second element is newly skipped image filenames. After `let output = ...`:

```swift
// Create skip records for images the plugin skipped at runtime
for filename in output.skippedImages {
    let record = JSONValue.object(["file": .string(filename), "plugin": .string(ctx.pluginIdentifier)])
    await ctx.stateStore.appendSkipRecord(image: filename, record: record)
}
```

Return the skipped images alongside the HookResult.

- [ ] **Step 6: Update PipelineOrchestrator.swift to collect runtime skips**

In `Sources/piqley/Pipeline/PipelineOrchestrator.swift`, where `runBinary` is called (around line 308), update to capture the returned skipped images and add them to the `skippedImages` set:

```swift
let (result, runtimeSkips) = try await runBinary(
    ctx, loadedPlugin: loadedPlugin,
    secrets: secrets, pluginConfig: pluginConfig,
    hookConfig: stageConfig.binary, manifestDeps: manifestDeps,
    rulesDidRun: preRulesDidRun, execLogPath: execLogPath,
    skipped: skipRecords,
    imageFolderURL: imageFolderURL,
    metadataBuffer: buffer,
    pipelineRunId: ctx.pipelineRunId
)
skippedImages.formUnion(runtimeSkips)
```

Update the switch statement below to use `result` from the tuple.

- [ ] **Step 7: Build and run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 8: Commit**

```
feat: create SkipRecords from plugin skip outcomes
```
