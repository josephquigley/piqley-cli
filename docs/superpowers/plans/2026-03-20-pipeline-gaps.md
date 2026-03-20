# Pipeline Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close five pre-dogfooding gaps: expanded image formats with warnings, rule negation + clone wildcard, fork/COW pipeline, config add-plugin command, and updated skeleton/docs.

**Architecture:** Changes span three repos linked via local path dependencies (piqley-core, piqley-cli, piqley-plugin-sdk). Core types change first, then CLI implementation, then SDK builders. Each task produces a commit. Feature branches in all three repos.

**Tech Stack:** Swift 6.0, macOS 15+, ImageIO/CoreGraphics, swift-argument-parser, swift-log

---

## File Structure

### piqley-core (wire types + validation)
- Modify: `Sources/PiqleyCore/Config/Rule.swift` — add `not` to MatchConfig and EmitConfig
- Modify: `Sources/PiqleyCore/Validation/RuleValidator.swift` — validate `not`, `writeBack`
- Modify: `Sources/PiqleyCore/Manifest/HookConfig.swift` — add `fork` field
- Modify: `Sources/PiqleyCore/Manifest/PluginManifest.swift` — add `supportedFormats`, `conversionFormat`
- Modify: `Sources/PiqleyCore/Validation/ManifestValidator.swift` — validate format fields
- Modify: `Tests/PiqleyCoreTests/RuleValidationTests.swift`
- Modify: `Tests/PiqleyCoreTests/ManifestValidatorTests.swift`
- Modify: `Tests/PiqleyCoreTests/HookConfigTests.swift` (or create if needed)

### piqley-cli (pipeline engine)
- Modify: `Sources/piqley/Pipeline/TempFolder.swift` — expand formats, return skipped files
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift` — fork management, format conversion, warnings
- Modify: `Sources/piqley/State/RuleEvaluator.swift` — negation, writeBack
- Modify: `Sources/piqley/State/MetadataBuffer.swift` — writeBack action support
- Modify: `Sources/piqley/CLI/ConfigCommand.swift` — register add-plugin/remove-plugin
- Modify: `Sources/piqley/Wizard/ConfigWizard.swift` — extract validation
- Create: `Sources/piqley/CLI/AddPluginCommand.swift`
- Create: `Sources/piqley/CLI/RemovePluginCommand.swift`
- Create: `Sources/piqley/Pipeline/ForkManager.swift` — fork creation, DAG resolution, writeBack
- Modify: `Tests/piqleyTests/TempFolderTests.swift`
- Modify: `Tests/piqleyTests/RuleEvaluatorTests.swift`
- Create: `Tests/piqleyTests/ForkManagerTests.swift`
- Create: `Tests/piqleyTests/AddPluginCommandTests.swift`

### piqley-plugin-sdk (builders + skeleton)
- Modify: `swift/PiqleyPluginSDK/Request.swift` — expand imageExtensions
- Modify: `swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift` — `not` on RuleMatch/RuleEmit
- Modify: `Skeletons/swift/Sources/main.swift` — hook branching
- Modify: `swift/Tests/ConfigBuilderTests.swift`

### Documentation (piqley-cli)
- Modify: `docs/plugin-sdk-guide.md`
- Modify: `docs/advanced-topics.md`

---

## Task 1: Rule negation — Core types

**Files:**
- Modify: `piqley-core/Sources/PiqleyCore/Config/Rule.swift`
- Modify: `piqley-core/Sources/PiqleyCore/Validation/RuleValidator.swift`
- Modify: `piqley-core/Tests/PiqleyCoreTests/RuleValidationTests.swift`

- [ ] **Step 1: Add `not` field to MatchConfig**

In `Rule.swift`, add `not: Bool?` to `MatchConfig`:

```swift
public struct MatchConfig: Codable, Sendable, Equatable {
    public let field: String
    public let pattern: String
    public let not: Bool?

    public init(field: String, pattern: String, not: Bool? = nil) {
        self.field = field
        self.pattern = pattern
        self.not = not
    }
}
```

- [ ] **Step 2: Add `not` field to EmitConfig**

In `Rule.swift`, add `not: Bool?` to `EmitConfig`:

```swift
public struct EmitConfig: Codable, Sendable, Equatable {
    public let action: String?
    public let field: String?
    public let values: [String]?
    public let replacements: [Replacement]?
    public let source: String?
    public let not: Bool?

    public init(action: String?, field: String?, values: [String]?, replacements: [Replacement]?, source: String?, not: Bool? = nil) {
        self.action = action
        self.field = field
        self.values = values
        self.replacements = replacements
        self.source = source
        self.not = not
    }
}
```

- [ ] **Step 3: Add `writeBack` to validActions and validate `not` in RuleValidator**

In `RuleValidator.swift`:
- Add `"writeBack"` to `validActions`
- In `validateEmit`, add `not` validation: reject `not: true` on `add`, `replace`, `clone`, `skip`, `writeBack`
- Add `"writeBack"` case with same constraints as `skip` (no field, values, replacements, source)

```swift
public static let validActions: Set<String> = ["add", "remove", "replace", "removeField", "clone", "skip", "writeBack"]
```

Add after the existing action switch in `validateEmit`, before `return .success`:

```swift
// Validate not field
if let not = emit.not, not {
    let action = emit.action ?? "add"
    let allowedNotActions: Set<String> = ["remove", "removeField"]
    if !allowedNotActions.contains(action) {
        return .failure(.notNotAllowed(action: action))
    }
}
```

Add `writeBack` case inside the switch:

```swift
case "writeBack":
    if emit.field != nil || emit.values != nil || emit.replacements != nil || emit.source != nil {
        return .failure(.conflictingFields(action: action))
    }
```

Add `notNotAllowed` to `RuleValidationError` enum (find it in the codebase and add the case).

- [ ] **Step 4: Update validateRule for writeBack constraints**

`writeBack` must only appear in `write` arrays. `validateRule` currently checks skip constraints. Add writeBack constraints:
- `writeBack` is rejected in `emit` arrays (must be in `write` only)
- `writeBack` must be alone in write array (like skip must be alone in emit)

```swift
let hasWriteBack = rule.write.contains { $0.action == "writeBack" }
if hasWriteBack {
    if rule.write.count > 1 {
        return .failure(.writeBackNotAlone)
    }
}
let hasEmitWriteBack = rule.emit.contains { $0.action == "writeBack" }
if hasEmitWriteBack {
    return .failure(.writeBackInEmit)
}
```

Add error cases `writeBackNotAlone` and `writeBackInEmit` to `RuleValidationError`.

- [ ] **Step 5: Write tests for negation and writeBack validation**

In `RuleValidationTests.swift`, add tests:
- `testMatchNotField`: MatchConfig with `not: true` decodes correctly
- `testEmitNotOnRemove`: EmitConfig with `not: true` on `remove` is valid
- `testEmitNotOnRemoveField`: EmitConfig with `not: true` on `removeField` is valid
- `testEmitNotOnAddRejected`: EmitConfig with `not: true` on `add` fails
- `testEmitNotOnCloneRejected`: EmitConfig with `not: true` on `clone` fails
- `testEmitNotOnSkipRejected`: EmitConfig with `not: true` on `skip` fails
- `testWriteBackValid`: writeBack EmitConfig with no fields passes
- `testWriteBackWithFieldRejected`: writeBack with field fails
- `testWriteBackInEmitRejected`: Rule with writeBack in emit array fails
- `testWriteBackNotAlone`: Rule with writeBack + other writes fails

- [ ] **Step 6: Run tests and commit**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test`
Expected: All tests pass.

```bash
git add -A && git commit -m "feat: add rule negation and writeBack validation to core types"
```

---

## Task 2: Rule negation — CLI evaluator

**Files:**
- Modify: `piqley-cli/Sources/piqley/State/RuleEvaluator.swift`
- Modify: `piqley-cli/Sources/piqley/State/MetadataBuffer.swift`
- Modify: `piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Add `not` to CompiledRule and invert match logic**

In `RuleEvaluator.swift`, add `not: Bool` to `CompiledRule`:

```swift
struct CompiledRule: Sendable {
    let namespace: String
    let field: String
    let matcher: any TagMatcher & Sendable
    let not: Bool
    let emitActions: [EmitAction]
    let writeActions: [EmitAction]
}
```

Update compilation in `init` to pass `rule.match.not ?? false`.

In `evaluate()`, after computing `matched`, apply negation:

```swift
let shouldApply = rule.not ? !matched : matched
```

Replace `if matched {` with `if shouldApply {`.

- [ ] **Step 2: Add negation to EmitAction for remove/removeField**

Add `not: Bool` to the relevant EmitAction cases:

```swift
case remove(field: String, matchers: [any TagMatcher & Sendable], not: Bool)
case removeField(field: String, not: Bool)
```

Update `compileEmitAction` to read `config.not ?? false` and pass it for `remove` and `removeField` cases.

- [ ] **Step 3: Implement negated remove and removeField in applyAction**

In `applyAction`, update the `remove` case:
- When `not: false` (default): remove values that match (existing behavior)
- When `not: true`: keep only values that match, remove everything else

```swift
case let .remove(field, matchers, not):
    var existing = extractStrings(from: working[field])
    if not {
        // Keep only matching values (allow-list)
        existing = existing.filter { value in
            matchers.contains { $0.matches(value) }
        }
    } else {
        // Remove matching values (block-list)
        existing.removeAll { value in
            matchers.contains { $0.matches(value) }
        }
    }
    if existing.isEmpty {
        working.removeValue(forKey: field)
    } else {
        working[field] = .array(existing.map { .string($0) })
    }
```

Update `removeField` case:
- When `not: false`: remove the specified field (existing behavior)
- When `not: true`: remove all fields EXCEPT the specified one

```swift
case let .removeField(field, not):
    if not {
        // Keep only this field, remove all others
        let kept = working[field]
        working.removeAll()
        if let kept { working[field] = kept }
    } else if field == "*" {
        working.removeAll()
    } else {
        working.removeValue(forKey: field)
    }
```

- [ ] **Step 4: Add writeBack case to EmitAction**

```swift
case writeBack
```

In `compileEmitAction`, add:

```swift
case "writeBack":
    return .writeBack
```

In `applyAction`, `writeBack` is a no-op (handled by the orchestrator):

```swift
case .writeBack:
    break
```

- [ ] **Step 5: Handle writeBack in MetadataBuffer.applyAction**

In `MetadataBuffer.swift`, `applyAction` calls `RuleEvaluator.applyAction` which is a no-op for writeBack. But we need the buffer to signal the orchestrator. Add a `writeBackTriggered` flag:

```swift
private(set) var writeBackTriggered = false

func applyAction(_ action: EmitAction, image: String) {
    if case .writeBack = action {
        writeBackTriggered = true
        return
    }
    // ... existing logic
}
```

- [ ] **Step 6: Write tests for negation in evaluator**

In `RuleEvaluatorTests.swift`, add:
- `testMatchNegation`: rule with `not: true` fires on non-matching images
- `testRemoveNegated`: `remove` with `not: true` keeps only matching values
- `testRemoveFieldNegated`: `removeField` with `not: true` keeps only named field
- `testRemoveFieldNegatedWithWrite`: same behavior in write actions via MetadataBuffer
- `testWriteBackCompiles`: writeBack action compiles without error

- [ ] **Step 7: Run tests and commit**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test`
Expected: All tests pass.

```bash
git add -A && git commit -m "feat: implement rule negation and writeBack in evaluator"
```

---

## Task 3: Image format expansion

**Files:**
- Modify: `piqley-cli/Sources/piqley/Pipeline/TempFolder.swift`
- Modify: `piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`
- Modify: `piqley-plugin-sdk/swift/PiqleyPluginSDK/Request.swift`
- Modify: `piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`
- Modify: `piqley-core/Sources/PiqleyCore/Validation/ManifestValidator.swift`
- Modify: `piqley-cli/Tests/piqleyTests/TempFolderTests.swift`
- Modify: `piqley-core/Tests/PiqleyCoreTests/ManifestValidatorTests.swift`

- [ ] **Step 1: Expand TempFolder.imageExtensions**

```swift
static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "jxl", "png", "tiff", "tif", "heic", "heif", "webp",
]
```

- [ ] **Step 2: Return skipped files from copyImages**

Change `copyImages` to return skipped filenames:

```swift
struct CopyResult: Sendable {
    let copiedCount: Int
    let skippedFiles: [String]
}

func copyImages(from sourceURL: URL) throws -> CopyResult {
    let contents = try FileManager.default.contentsOfDirectory(
        at: sourceURL, includingPropertiesForKeys: nil
    )
    var copiedCount = 0
    var skippedFiles: [String] = []
    for file in contents {
        let name = file.lastPathComponent
        guard !name.hasPrefix(".") else { continue }
        guard Self.imageExtensions.contains(file.pathExtension.lowercased()) else {
            skippedFiles.append(name)
            continue
        }
        let destination = url.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: destination)
        copiedCount += 1
    }
    return CopyResult(copiedCount: copiedCount, skippedFiles: skippedFiles)
}
```

- [ ] **Step 3: Log warnings and abort on zero in PipelineOrchestrator**

Update `run()` where `temp.copyImages` is called:

```swift
let copyResult = try temp.copyImages(from: sourceURL)
for skipped in copyResult.skippedFiles {
    logger.warning("Skipping '\(skipped)': unsupported format")
}
if copyResult.copiedCount == 0 {
    logger.error("No supported image files found in \(sourceURL.path)")
    try? temp.delete()
    return false
}
```

- [ ] **Step 4: Update SDK imageExtensions**

In `piqley-plugin-sdk/swift/PiqleyPluginSDK/Request.swift`, update:

```swift
private static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "jxl", "png", "tiff", "tif", "heic", "heif", "webp",
]
```

- [ ] **Step 5: Add supportedFormats and conversionFormat to PluginManifest**

In `PluginManifest.swift`, add properties:

```swift
public let supportedFormats: [String]?
public let conversionFormat: String?
```

Update both `init` and coding.

- [ ] **Step 6: Validate format fields in ManifestValidator**

Add validation: `conversionFormat` without `supportedFormats` is an error.

- [ ] **Step 7: Write tests and commit**

Test: TempFolder skipping unsupported files, ManifestValidator format validation.

Run: `swift test` in all three repos.

```bash
# In each repo:
git add -A && git commit -m "feat: expand supported image formats with warnings"
```

---

## Task 4: Fork/COW pipeline — HookConfig + ForkManager

**Files:**
- Modify: `piqley-core/Sources/PiqleyCore/Manifest/HookConfig.swift`
- Create: `piqley-cli/Sources/piqley/Pipeline/ForkManager.swift`
- Modify: `piqley-cli/Sources/piqley/Pipeline/TempFolder.swift`
- Create: `piqley-cli/Tests/piqleyTests/ForkManagerTests.swift`

- [ ] **Step 1: Add `fork` to HookConfig**

In `HookConfig.swift`, add `fork: Bool?` property:

```swift
public let fork: Bool?
```

Add to `init`, `CodingKeys`, `init(from:)`, and `encode(to:)`.

- [ ] **Step 2: Create ForkManager**

Create `ForkManager.swift` in `piqley-cli/Sources/piqley/Pipeline/`:

```swift
import Foundation
import Logging
import PiqleyCore

/// Manages fork (COW) folders for plugins that need isolated image copies.
actor ForkManager {
    private let baseURL: URL
    private var forkPaths: [String: URL] = [:]
    private let logger = Logger(label: "piqley.fork")

    init(baseURL: URL) {
        self.baseURL = baseURL.appendingPathComponent("forks")
    }

    /// Creates or returns existing fork folder for a plugin.
    /// sourceURL is either main or another plugin's fork.
    func getOrCreateFork(
        pluginId: String,
        sourceURL: URL,
        manifest: PluginManifest? = nil
    ) throws -> URL {
        if let existing = forkPaths[pluginId] {
            return existing
        }

        let forkURL = baseURL.appendingPathComponent(pluginId)
        try FileManager.default.createDirectory(at: forkURL, withIntermediateDirectories: true)

        // Copy images from source, with optional format conversion
        let supportedFormats = manifest?.supportedFormats.map { Set($0) }
        let conversionFormat = manifest?.conversionFormat

        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let ext = file.pathExtension.lowercased()
            guard TempFolder.imageExtensions.contains(ext) else { continue }

            if let supported = supportedFormats, !supported.contains(ext) {
                if let target = conversionFormat {
                    // Convert and copy
                    let newName = (name as NSString).deletingPathExtension + "." + target
                    let destination = forkURL.appendingPathComponent(newName)
                    try ImageConverter.convert(from: file, to: destination, format: target)
                } else {
                    logger.warning("Skipping '\(name)' for plugin '\(pluginId)': unsupported format")
                }
            } else {
                let destination = forkURL.appendingPathComponent(name)
                try FileManager.default.copyItem(at: file, to: destination)
            }
        }

        forkPaths[pluginId] = forkURL
        return forkURL
    }

    /// Resolve the image source for a plugin based on its dependencies and fork status.
    func resolveSource(
        pluginId: String,
        dependencies: [String],
        pipeline: [(hook: String, pluginId: String)],
        mainURL: URL
    ) -> URL {
        // Find the dependency that ran most recently and has a fork
        let executionOrder = pipeline.map(\.pluginId)
        var latestForkingDep: String?
        var latestIndex = -1

        for dep in dependencies {
            if let forkPath = forkPaths[dep],
               FileManager.default.fileExists(atPath: forkPath.path),
               let idx = executionOrder.lastIndex(of: dep),
               idx > latestIndex
            {
                latestForkingDep = dep
                latestIndex = idx
            }
        }

        if let dep = latestForkingDep, let path = forkPaths[dep] {
            return path
        }
        return mainURL
    }

    /// Write back fork contents to main.
    func writeBack(pluginId: String, mainURL: URL) throws {
        guard let forkURL = forkPaths[pluginId] else { return }

        let contents = try FileManager.default.contentsOfDirectory(
            at: forkURL, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let destination = mainURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: file, to: destination)
        }
        logger.info("writeBack from '\(pluginId)' to main")
    }

    func hasFork(_ pluginId: String) -> Bool {
        forkPaths[pluginId] != nil
    }
}
```

- [ ] **Step 3: Create ImageConverter utility**

Create `piqley-cli/Sources/piqley/Pipeline/ImageConverter.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageConverter {
    static func convert(from source: URL, to destination: URL, format: String) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw ConversionError.cannotReadSource(source.lastPathComponent)
        }

        let uti = utiForFormat(format)
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }

        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.finalizeFailed(destination.lastPathComponent)
        }
    }

    private static func utiForFormat(_ format: String) -> String {
        switch format.lowercased() {
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "tiff", "tif": return "public.tiff"
        case "heic", "heif": return "public.heic"
        case "webp": return "public.webp"
        default: return "public.jpeg"
        }
    }

    enum ConversionError: Error, LocalizedError {
        case cannotReadSource(String)
        case cannotCreateDestination(String)
        case finalizeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .cannotReadSource(f): "Cannot read image: \(f)"
            case let .cannotCreateDestination(f): "Cannot create destination: \(f)"
            case let .finalizeFailed(f): "Image conversion failed: \(f)"
            }
        }
    }
}
```

- [ ] **Step 4: Write ForkManager tests**

Test: fork creation, source resolution (main vs dependency fork), writeBack, format conversion triggering fork.

- [ ] **Step 5: Run tests and commit**

Run: `swift test` in piqley-core and piqley-cli.

```bash
git add -A && git commit -m "feat: add fork/COW pipeline infrastructure"
```

---

## Task 5: Fork integration into PipelineOrchestrator

**Files:**
- Modify: `piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`
- Modify: `piqley-cli/Sources/piqley/State/MetadataBuffer.swift`

- [ ] **Step 1: Add ForkManager to PipelineOrchestrator.run()**

In `run()`, create ForkManager alongside TempFolder:

```swift
let forkManager = ForkManager(baseURL: temp.url)
```

Pass `forkManager` through `HookContext`.

- [ ] **Step 2: Determine imageFolderPath per plugin**

In `runPluginHook`, after loading the plugin and stage config, determine whether this plugin forks:

```swift
let shouldFork = stageConfig.binary?.fork == true
    || loadedPlugin.manifest.conversionFormat != nil

let imageFolderURL: URL
if shouldFork {
    let deps = loadedPlugin.manifest.dependencyIdentifiers
    let source = await forkManager.resolveSource(
        pluginId: ctx.pluginIdentifier,
        dependencies: deps,
        pipeline: ctx.executedPlugins,
        mainURL: ctx.temp.url
    )
    imageFolderURL = try await forkManager.getOrCreateFork(
        pluginId: ctx.pluginIdentifier,
        sourceURL: source,
        manifest: loadedPlugin.manifest
    )
} else {
    // Check if any dependency has a fork (non-forking plugin depending on forking plugin)
    let deps = loadedPlugin.manifest.dependencyIdentifiers
    let source = await forkManager.resolveSource(
        pluginId: ctx.pluginIdentifier,
        dependencies: deps,
        pipeline: ctx.executedPlugins,
        mainURL: ctx.temp.url
    )
    imageFolderURL = source
}
```

Update `imageFiles` filtering to use `imageFolderURL` instead of `ctx.temp.url`.

- [ ] **Step 3: Handle writeBack after post-rules**

After post-rules evaluation, check if writeBack was triggered:

```swift
if buffer.writeBackTriggered {
    try await forkManager.writeBack(pluginId: ctx.pluginIdentifier, mainURL: ctx.temp.url)
}
```

- [ ] **Step 4: Track executed plugins for DAG resolution**

Add `executedPlugins: [(hook: String, pluginId: String)]` to `HookContext` and append each plugin as it executes.

- [ ] **Step 5: Pass fork URL to PluginRunner**

Update `runBinary` to pass the resolved `imageFolderURL` instead of `ctx.temp.url`. The PluginRunner's `buildJSONPayload` already accepts a folder path parameter.

- [ ] **Step 6: Run tests and commit**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test`

```bash
git add -A && git commit -m "feat: integrate fork/COW into pipeline orchestrator"
```

---

## Task 6: config add-plugin and remove-plugin commands

**Files:**
- Modify: `piqley-cli/Sources/piqley/Wizard/ConfigWizard.swift`
- Create: `piqley-cli/Sources/piqley/CLI/AddPluginCommand.swift`
- Create: `piqley-cli/Sources/piqley/CLI/RemovePluginCommand.swift`
- Modify: `piqley-cli/Sources/piqley/CLI/ConfigCommand.swift`

- [ ] **Step 1: Extract validation from ConfigWizard into shared function**

Create a `PipelineEditor` enum (or extension on AppConfig) with a static validation method:

```swift
enum PipelineEditor {
    struct AddResult {
        let pluginIdentifier: String
        let stage: String
    }

    enum AddError: Error, CustomStringConvertible {
        case pluginNotFound(String)
        case noStageFile(plugin: String, stage: String)
        case alreadyInStage(plugin: String, stage: String)
        case invalidStage(String)

        var description: String {
            switch self {
            case let .pluginNotFound(id): "Plugin '\(id)' not found"
            case let .noStageFile(p, s): "Plugin '\(p)' has no stage file for '\(s)'"
            case let .alreadyInStage(p, s): "Plugin '\(p)' is already in '\(s)' pipeline"
            case let .invalidStage(s): "'\(s)' is not a valid pipeline stage"
            }
        }
    }

    static func validateAdd(
        pluginId: String,
        stage: String,
        config: AppConfig,
        discoveredPlugins: [LoadedPlugin]
    ) throws {
        let validStages = Set(Hook.allCases.map(\.rawValue))
        guard validStages.contains(stage) else {
            throw AddError.invalidStage(stage)
        }
        guard let plugin = discoveredPlugins.first(where: { $0.identifier == pluginId }) else {
            throw AddError.pluginNotFound(pluginId)
        }
        guard plugin.stages[stage] != nil else {
            throw AddError.noStageFile(plugin: pluginId, stage: stage)
        }
        let current = Set(config.pipeline[stage] ?? [])
        guard !current.contains(pluginId) else {
            throw AddError.alreadyInStage(plugin: pluginId, stage: stage)
        }
    }
}
```

Update `ConfigWizard.addPlugin()` to call `PipelineEditor.validateAdd`.

- [ ] **Step 2: Create AddPluginCommand**

```swift
extension ConfigCommand {
    struct AddPluginSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-plugin",
            abstract: "Add a plugin to a pipeline stage"
        )

        @Argument(help: "Plugin identifier")
        var pluginIdentifier: String

        @Argument(help: "Pipeline stage (pre-process, post-process, publish, post-publish)")
        var stage: String

        @Option(help: "Position in the stage (0-based index, appends if omitted)")
        var position: Int?

        func run() throws {
            var config = try AppConfig.load()
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            try PipelineEditor.validateAdd(
                pluginId: pluginIdentifier, stage: stage,
                config: config, discoveredPlugins: plugins
            )

            var list = config.pipeline[stage] ?? []
            if let pos = position, pos >= 0, pos <= list.count {
                list.insert(pluginIdentifier, at: pos)
            } else {
                list.append(pluginIdentifier)
            }
            config.pipeline[stage] = list
            try config.save()

            print("Added '\(pluginIdentifier)' to \(stage) pipeline")
        }
    }
}
```

- [ ] **Step 3: Create RemovePluginCommand**

Similar structure. Validates plugin exists in stage. Warns if other plugins depend on it.

- [ ] **Step 4: Register commands in ConfigCommand**

Add `AddPluginSubcommand.self` and `RemovePluginSubcommand.self` to `ConfigCommand.configuration.subcommands`.

- [ ] **Step 5: Run tests and commit**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test`

```bash
git add -A && git commit -m "feat: add config add-plugin and remove-plugin commands"
```

---

## Task 7: SDK builders + skeleton update

**Files:**
- Modify: `piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`
- Modify: `piqley-plugin-sdk/Skeletons/swift/Sources/main.swift`
- Modify: `piqley-plugin-sdk/swift/Tests/ConfigBuilderTests.swift`

- [ ] **Step 1: Add `not` to RuleMatch**

```swift
public struct RuleMatch: Sendable {
    let field: MatchField
    let pattern: MatchPattern
    let not: Bool

    private init(field: MatchField, pattern: MatchPattern, not: Bool = false) {
        self.field = field
        self.pattern = pattern
        self.not = not
    }

    public static func field(_ field: MatchField, pattern: MatchPattern, not: Bool = false) -> RuleMatch {
        RuleMatch(field: field, pattern: pattern, not: not)
    }

    func toMatchConfig() -> MatchConfig {
        MatchConfig(field: field.encoded, pattern: pattern.encoded, not: not ? true : nil)
    }
}
```

- [ ] **Step 2: Add `not` and `writeBack` to RuleEmit**

Add new cases:

```swift
case writeBack
```

Update `toEmitConfig` for writeBack:

```swift
case .writeBack:
    EmitConfig(action: "writeBack", field: nil, values: nil, replacements: nil, source: nil)
```

For existing `remove`, `removeField` cases, add `not` parameter variants or a modifier.

- [ ] **Step 3: Update skeleton with hook branching**

Replace `Skeletons/swift/Sources/main.swift`:

```swift
import PiqleyPluginSDK

@main
struct Plugin: PiqleyPlugin {
    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        switch request.hook {
        case .preProcess:
            return try await preProcess(request)
        case .postProcess:
            return try await postProcess(request)
        case .publish:
            return try await publish(request)
        case .postPublish:
            return try await postPublish(request)
        }
    }

    private func preProcess(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add pre-process logic
        return .ok
    }

    private func postProcess(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add post-process logic
        return .ok
    }

    private func publish(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add publish logic
        return .ok
    }

    private func postPublish(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Add post-publish logic
        return .ok
    }
}
```

- [ ] **Step 4: Write tests and commit**

Add tests for `not` on `RuleMatch.toMatchConfig()` and `RuleEmit.writeBack.toEmitConfig()`.

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test`

```bash
git add -A && git commit -m "feat: add negation and writeBack to SDK builders, update skeleton"
```

---

## Task 8: Documentation updates

**Files:**
- Modify: `piqley-cli/docs/plugin-sdk-guide.md`
- Modify: `piqley-cli/docs/advanced-topics.md`

- [ ] **Step 1: Update plugin-sdk-guide.md**

Add/update sections:
- "The Plugin Protocol" — show hook-branching pattern
- "Multi-Stage Plugins" — one binary handles all stages
- "Format Declarations" — `supportedFormats`, `conversionFormat`
- "Fork/COW Pipeline" — how to declare `fork: true`, fork lifetime, writeBack as rule effect
- "Rule Negation" — `not` on match and emit, allow-list examples
- "Clone Wildcard" — `clone *` composition with negation

- [ ] **Step 2: Update advanced-topics.md**

Add sections:
- "Fork Pipeline Workflow" — full sanitized workflow narrative (Privacy Stripper through Watermark Database) with ASCII DAG
- "Rule Composition Patterns" — negation + clone wildcard examples

- [ ] **Step 3: Commit docs**

```bash
git add -A && git commit -m "docs: update SDK guide and advanced topics with fork, negation, and format features"
```

---

## Task 9: Final integration test

- [ ] **Step 1: Run full test suite across all repos**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift test
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test
```

- [ ] **Step 2: Build CLI to verify compilation**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build
```

- [ ] **Step 3: Fix any issues found, re-run tests**
