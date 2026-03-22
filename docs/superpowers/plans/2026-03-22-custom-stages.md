# Custom Stages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed `Hook` enum as the source of truth for pipeline stages with a global stage registry that supports user-defined custom stages.

**Architecture:** A `StageRegistry` struct in PiqleyCore manages a `stages.json` file with `active` (ordered, executed) and `available` (discovered, not yet placed) lists. Plugin discovery auto-registers unknown stage files into `available`. The orchestrator, TUI, and validation all read from the registry instead of `Hook.allCases`/`Hook.canonicalOrder`.

**Tech Stack:** Swift, PiqleyCore library, piqley-cli

---

### Task 1: StageRegistry Data Model in PiqleyCore

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/Config/StageRegistry.swift`
- Create: `piqley-core/Tests/PiqleyCoreTests/StageRegistryTests.swift`
- Modify: `piqley-core/Sources/PiqleyCore/Hook.swift:1-19`

- [ ] **Step 1: Write failing tests for StageRegistry**

```swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("StageRegistry")
struct StageRegistryTests {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-registry-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test func seedsDefaultsWhenFileMissing() throws {
        let registry = try StageRegistry.load(from: tempDir)
        #expect(registry.active.map(\.name) == Hook.defaultStageNames)
        #expect(registry.available.isEmpty)
    }

    @Test func roundTrips() throws {
        var registry = try StageRegistry.load(from: tempDir)
        registry.available.append(StageEntry(name: "publish-356"))
        try registry.save(to: tempDir)
        let reloaded = try StageRegistry.load(from: tempDir)
        #expect(reloaded.available.map(\.name) == ["publish-356"])
    }

    @Test func isKnownChecksActivePlusAvailable() throws {
        var registry = try StageRegistry.load(from: tempDir)
        registry.available.append(StageEntry(name: "custom"))
        #expect(registry.isKnown("pre-process"))
        #expect(registry.isKnown("custom"))
        #expect(!registry.isKnown("nonexistent"))
    }

    @Test func validatesStageNames() {
        #expect(StageRegistry.isValidName("pre-process"))
        #expect(StageRegistry.isValidName("publish-356-project"))
        #expect(!StageRegistry.isValidName("-leading"))
        #expect(!StageRegistry.isValidName("trailing-"))
        #expect(!StageRegistry.isValidName("Capital"))
        #expect(!StageRegistry.isValidName("has spaces"))
        #expect(!StageRegistry.isValidName("a")) // minimum 2 chars
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter StageRegistryTests 2>&1 | head -30`
Expected: Compilation errors, types not found

- [ ] **Step 3: Implement StageRegistry**

```swift
// piqley-core/Sources/PiqleyCore/Config/StageRegistry.swift
import Foundation

public struct StageEntry: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct StageRegistry: Codable, Sendable {
    public static let fileName = "stages.json"

    public var schemaVersion: Int = 1
    public var active: [StageEntry]
    public var available: [StageEntry]

    public init(active: [StageEntry] = [], available: [StageEntry] = []) {
        self.active = active
        self.available = available
    }

    // MARK: - Persistence

    public static func load(from directory: URL) throws -> StageRegistry {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            let seeded = StageRegistry(
                active: Hook.defaultStageNames.map { StageEntry(name: $0) },
                available: []
            )
            try seeded.save(to: directory)
            return seeded
        }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(StageRegistry.self, from: data)
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    // MARK: - Queries

    public var allKnownNames: Set<String> {
        Set(active.map(\.name) + available.map(\.name))
    }

    public func isKnown(_ name: String) -> Bool {
        allKnownNames.contains(name)
    }

    public var executionOrder: [String] {
        active.map(\.name)
    }

    // MARK: - Validation

    private static let namePattern = /^[a-z0-9][a-z0-9-]*[a-z0-9]$/

    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: namePattern) != nil
    }
}
```

- [ ] **Step 4: Add `defaultStageNames` to Hook**

In `piqley-core/Sources/PiqleyCore/Hook.swift`, add after `canonicalOrder`:

```swift
/// Default stage names used to seed the stage registry.
public static let defaultStageNames: [String] = canonicalOrder.map(\.rawValue)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter StageRegistryTests 2>&1`
Expected: All tests pass

- [ ] **Step 6: Commit**

Message: `feat(core): add StageRegistry data model with persistence and validation`

---

### Task 2: StageRegistry Mutation Methods

**Files:**
- Modify: `piqley-core/Sources/PiqleyCore/Config/StageRegistry.swift`
- Modify: `piqley-core/Tests/PiqleyCoreTests/StageRegistryTests.swift`

- [ ] **Step 1: Write failing tests for mutations**

```swift
@Test func activateMovesFromAvailableToActive() throws {
    var registry = try StageRegistry.load(from: tempDir)
    registry.available.append(StageEntry(name: "custom"))
    try registry.activate("custom", at: 2)
    #expect(registry.active[2].name == "custom")
    #expect(registry.available.isEmpty)
}

@Test func deactivateMovesFromActiveToAvailable() throws {
    var registry = try StageRegistry.load(from: tempDir)
    try registry.deactivate("pre-process")
    #expect(!registry.active.map(\.name).contains("pre-process"))
    #expect(registry.available.map(\.name).contains("pre-process"))
}

@Test func reorderMovesStageTo() throws {
    var registry = try StageRegistry.load(from: tempDir)
    // Move "publish" (index 3) to index 1
    try registry.reorder("publish", to: 1)
    #expect(registry.active[1].name == "publish")
}

@Test func addStageInsertsAtPosition() throws {
    var registry = try StageRegistry.load(from: tempDir)
    try registry.addStage("custom-stage", at: 2)
    #expect(registry.active[2].name == "custom-stage")
    #expect(registry.active.count == 7)
}

@Test func addStageDuplicateNameThrows() throws {
    var registry = try StageRegistry.load(from: tempDir)
    #expect(throws: StageRegistryError.self) {
        try registry.addStage("pre-process", at: 0)
    }
}

@Test func addStageInvalidNameThrows() throws {
    var registry = try StageRegistry.load(from: tempDir)
    #expect(throws: StageRegistryError.self) {
        try registry.addStage("Bad Name", at: 0)
    }
}

@Test func removeStageDeletesFromBothLists() throws {
    var registry = try StageRegistry.load(from: tempDir)
    registry.available.append(StageEntry(name: "custom"))
    try registry.removeStage("custom")
    #expect(!registry.isKnown("custom"))
}

@Test func renameStageUpdatesName() throws {
    var registry = try StageRegistry.load(from: tempDir)
    try registry.renameStage("publish", to: "publish-photos")
    #expect(registry.active.map(\.name).contains("publish-photos"))
    #expect(!registry.active.map(\.name).contains("publish"))
}

@Test func renameToExistingNameThrows() throws {
    var registry = try StageRegistry.load(from: tempDir)
    #expect(throws: StageRegistryError.self) {
        try registry.renameStage("publish", to: "pre-process")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter StageRegistryTests 2>&1 | head -30`
Expected: Compilation errors

- [ ] **Step 3: Implement mutation methods and error type**

Add to `StageRegistry.swift`:

```swift
public enum StageRegistryError: Error, CustomStringConvertible {
    case stageNotFound(String)
    case stageAlreadyExists(String)
    case invalidName(String)
    case indexOutOfBounds

    public var description: String {
        switch self {
        case let .stageNotFound(name): "Stage '\(name)' not found"
        case let .stageAlreadyExists(name): "Stage '\(name)' already exists"
        case let .invalidName(name): "'\(name)' is not a valid stage name"
        case .indexOutOfBounds: "Index out of bounds"
        }
    }
}
```

Add mutation methods to `StageRegistry`:

```swift
// MARK: - Mutations

public mutating func addStage(_ name: String, at index: Int) throws {
    guard Self.isValidName(name) else { throw StageRegistryError.invalidName(name) }
    guard !isKnown(name) else { throw StageRegistryError.stageAlreadyExists(name) }
    guard index >= 0, index <= active.count else { throw StageRegistryError.indexOutOfBounds }
    active.insert(StageEntry(name: name), at: index)
}

public mutating func activate(_ name: String, at index: Int) throws {
    guard let availIdx = available.firstIndex(where: { $0.name == name }) else {
        throw StageRegistryError.stageNotFound(name)
    }
    guard index >= 0, index <= active.count else { throw StageRegistryError.indexOutOfBounds }
    let entry = available.remove(at: availIdx)
    active.insert(entry, at: index)
}

public mutating func deactivate(_ name: String) throws {
    guard let idx = active.firstIndex(where: { $0.name == name }) else {
        throw StageRegistryError.stageNotFound(name)
    }
    let entry = active.remove(at: idx)
    available.append(entry)
}

public mutating func removeStage(_ name: String) throws {
    if let idx = active.firstIndex(where: { $0.name == name }) {
        active.remove(at: idx)
    } else if let idx = available.firstIndex(where: { $0.name == name }) {
        available.remove(at: idx)
    } else {
        throw StageRegistryError.stageNotFound(name)
    }
}

public mutating func reorder(_ name: String, to newIndex: Int) throws {
    guard let oldIndex = active.firstIndex(where: { $0.name == name }) else {
        throw StageRegistryError.stageNotFound(name)
    }
    guard newIndex >= 0, newIndex < active.count else { throw StageRegistryError.indexOutOfBounds }
    let entry = active.remove(at: oldIndex)
    active.insert(entry, at: newIndex)
}

public mutating func renameStage(_ oldName: String, to newName: String) throws {
    guard Self.isValidName(newName) else { throw StageRegistryError.invalidName(newName) }
    guard !isKnown(newName) else { throw StageRegistryError.stageAlreadyExists(newName) }
    if let idx = active.firstIndex(where: { $0.name == oldName }) {
        active[idx].name = newName
    } else if let idx = available.firstIndex(where: { $0.name == oldName }) {
        available[idx].name = newName
    } else {
        throw StageRegistryError.stageNotFound(oldName)
    }
}

/// Register an unknown stage name into the available list.
/// No-op if the name is already known.
public mutating func autoRegister(_ name: String) {
    guard !isKnown(name) else { return }
    available.append(StageEntry(name: name))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter StageRegistryTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

Message: `feat(core): add StageRegistry mutation methods`

---

### Task 3: Wire StageRegistry Into PluginDiscovery

**Files:**
- Modify: `piqley-cli/Sources/piqley/Plugins/PluginDiscovery.swift:44,89-112`
- Modify: `piqley-cli/Sources/piqley/Constants/PiqleyPath.swift:1-6`

- [ ] **Step 1: Add stages path to PiqleyPath**

In `piqley-cli/Sources/piqley/Constants/PiqleyPath.swift`, add:

```swift
static let stages = ".config/piqley"
```

This is the directory where `stages.json` lives (same parent as workflows).

- [ ] **Step 2: Update PluginDiscovery to accept registry**

In `piqley-cli/Sources/piqley/Plugins/PluginDiscovery.swift`:

Replace line 44:
```swift
let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))
```
with:
```swift
let knownHooks = registry.allKnownNames
```

Add `registry` parameter to the struct and `loadManifests`:

```swift
struct PluginDiscovery: Sendable {
    let pluginsDirectory: URL
    let registry: StageRegistry
    private let logger = Logger(label: "piqley.discovery")

    func loadManifests() throws -> (plugins: [LoadedPlugin], registry: StageRegistry) {
        var updatedRegistry = registry
        // ... existing code but using updatedRegistry ...
        return (plugins, updatedRegistry)
    }
}
```

- [ ] **Step 3: Update loadStages to auto-register unknown stages**

In `loadStages`, replace the `knownHooks` guard (lines 109-112):

```swift
guard knownHooks.contains(stageName) else {
    logger.warning("Plugin '\(pluginDir.lastPathComponent)' has unknown stage '\(stageName)' — ignored")
    continue
}
```

With acceptance of all valid stage names, collecting new ones:

```swift
if !knownHooks.contains(stageName) {
    newStageNames.insert(stageName)
}
```

Update the method signature to return new stage names:

```swift
static func loadStages(
    from pluginDir: URL, knownHooks: Set<String>,
    logger: Logger = Logger(label: "piqley.discovery")
) -> (stages: [String: StageConfig], newStageNames: Set<String>) {
    var stages: [String: StageConfig] = [:]
    var newStageNames: Set<String> = []
    // ... existing parsing, but collect newStageNames instead of rejecting ...
    return (stages, newStageNames)
}
```

In `loadManifests`, after calling `loadStages`, auto-register new names:

```swift
let (stages, newStageNames) = Self.loadStages(from: url, knownHooks: knownHooks, logger: logger)
for name in newStageNames {
    updatedRegistry.autoRegister(name)
}
```

- [ ] **Step 4: Update all call sites of PluginDiscovery**

Search for `PluginDiscovery(pluginsDirectory:` across the CLI and update each to pass a registry. The main call sites are:

- `WorkflowCommand.swift` (EditSubcommand, CreateSubcommand, AddPluginSubcommand, RemovePluginSubcommand)
- `PipelineOrchestrator.swift` (if it creates PluginDiscovery)

At each site, load the registry first:

```swift
let stagesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(PiqleyPath.stages)
var registry = try StageRegistry.load(from: stagesDir)
let discovery = PluginDiscovery(pluginsDirectory: pluginsDir, registry: registry)
let (plugins, updatedRegistry) = try discovery.loadManifests()
registry = updatedRegistry
try registry.save(to: stagesDir)
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

Message: `feat: wire StageRegistry into PluginDiscovery with auto-registration`

---

### Task 4: Update PipelineEditor Validation

**Files:**
- Modify: `piqley-cli/Sources/piqley/Config/PipelineEditor.swift:33-68`

- [ ] **Step 1: Update validateAdd to use registry**

Replace lines 33-52 of `PipelineEditor.swift`:

Change the `validStages` line from:
```swift
let validStages = Set(Hook.allCases.map(\.rawValue))
```
to accept a registry parameter:
```swift
static func validateAdd(
    pluginId: String,
    stage: String,
    workflow: Workflow,
    discoveredPlugins: [LoadedPlugin],
    registry: StageRegistry
) throws {
    guard registry.isKnown(stage) else {
        throw AddError.invalidStage(stage)
    }
    // ... rest stays the same ...
}
```

- [ ] **Step 2: Update validateRemove to use registry**

Same change for `validateRemove` (lines 55-68):

```swift
static func validateRemove(
    pluginId: String,
    stage: String,
    workflow: Workflow,
    registry: StageRegistry
) throws {
    guard registry.isKnown(stage) else {
        throw RemoveError.invalidStage(stage)
    }
    // ... rest stays the same ...
}
```

- [ ] **Step 3: Update call sites in WorkflowCommand**

In `WorkflowCommand.swift`, update `AddPluginSubcommand.run()` and `RemovePluginSubcommand.run()` to pass the registry to the validation methods.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

Message: `refactor: update PipelineEditor validation to use StageRegistry`

---

### Task 5: Update Workflow.empty to Use Registry

**Files:**
- Modify: `piqley-cli/Sources/piqley/Config/Workflow.swift:12-20`

- [ ] **Step 1: Update Workflow.empty to accept stage list**

Replace the `Workflow.empty` factory:

```swift
/// Creates a new empty workflow with all active stages initialized to empty arrays.
static func empty(
    name: String,
    displayName: String = "",
    description: String = "",
    activeStages: [String]
) -> Workflow {
    Workflow(
        name: name,
        displayName: displayName.isEmpty ? name : displayName,
        description: description,
        pipeline: Dictionary(uniqueKeysWithValues: activeStages.map { ($0, [String]()) })
    )
}
```

- [ ] **Step 2: Update call sites**

In `WorkflowStore.seedDefault()` (line 79) and `WorkflowCommand.CreateSubcommand.run()` (line 78), pass the active stages from the registry:

```swift
// Where registry is available:
let workflow = Workflow.empty(
    name: workflowName,
    displayName: workflowName,
    activeStages: registry.executionOrder
)
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

Message: `refactor: Workflow.empty uses registry active stages instead of Hook enum`

---

### Task 6: Update PipelineOrchestrator to Use Registry

**Files:**
- Modify: `piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift:86-178`

- [ ] **Step 1: Add registry property to PipelineOrchestrator**

Add to the struct properties (after line 8):

```swift
let registry: StageRegistry
```

- [ ] **Step 2: Replace lifecycle-separated execution with flat loop**

Replace lines 86-178 (the hook execution section) with a flat loop over the registry's execution order:

```swift
// Execute hooks in order from registry
logger.info("Pipeline run \(pipelineRunId) starting")
var skippedImages: Set<String> = []
var executedPlugins: [(hook: String, pluginId: String)] = []
var pipelineFailed = false

for stage in registry.executionOrder {
    guard !pipelineFailed else { break }

    for pluginEntry in pipeline[stage] ?? [] {
        guard !blocklist.isBlocked(pluginEntry) else {
            logger.debug("[\(pluginEntry)] skipped (blocklisted)")
            continue
        }

        let ctx = HookContext(
            pluginIdentifier: pluginEntry, pluginName: pluginEntry,
            hook: stage, temp: temp,
            stateStore: stateStore, imageFiles: imageFiles,
            dryRun: dryRun, nonInteractive: nonInteractive,
            skippedImages: skippedImages,
            forkManager: forkManager,
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

logger.info("Pipeline run \(pipelineRunId) finished")
```

- [ ] **Step 3: Update all PipelineOrchestrator construction sites**

Search for `PipelineOrchestrator(` and add the `registry` parameter at each call site.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Run existing orchestrator tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter PipelineOrchestratorTests 2>&1`
Expected: Tests pass (may need minor updates to construct registry in test helpers)

- [ ] **Step 6: Commit**

Message: `refactor: PipelineOrchestrator uses StageRegistry execution order`

---

### Task 7: Terminal Input Helper for Stage Names

**Files:**
- Modify: `piqley-cli/Sources/piqley/Terminal/RawTerminal.swift` (or wherever `promptForInput` needs to be added)

Note: The CRUD methods in Task 8 use `terminal.promptForInput(title:)`. This must exist before Task 8 compiles.

- [ ] **Step 1: Check if promptForInput exists**

Search for `promptForInput` in the codebase. If missing, implement it.

- [ ] **Step 2: Implement promptForInput if needed**

```swift
func promptForInput(title: String) -> String? {
    var buf = ""
    buf += ANSI.clearScreen()
    buf += ANSI.moveTo(row: 1, col: 1)
    buf += "\(ANSI.bold)\(title):\(ANSI.reset)"
    buf += ANSI.moveTo(row: 3, col: 1)
    buf += "> "
    write(buf)

    var input = ""
    while true {
        let key = readKey()
        switch key {
        case .char(let c):
            input.append(c)
            write(String(c))
        case .backspace:
            if !input.isEmpty {
                input.removeLast()
                write("\u{08} \u{08}")
            }
        case .enter:
            return input.isEmpty ? nil : input
        case .escape, .ctrlC:
            return nil
        default: break
        }
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

Message: `feat: add promptForInput to RawTerminal for stage name entry`

---

### Task 8: TUI Stage CRUD Operations

**Files:**
- Modify: `piqley-cli/Sources/piqley/Wizard/ConfigWizard.swift:4-64`
- Create: `piqley-cli/Sources/piqley/Wizard/ConfigWizard+Stages.swift`

- [ ] **Step 1: Add registry to ConfigWizard**

In `ConfigWizard.swift`, add a mutable registry property:

```swift
var registry: StageRegistry
```

Update `init` to accept it:

```swift
init(workflow: Workflow, discoveredPlugins: [LoadedPlugin], registry: StageRegistry) {
    self.workflow = workflow
    self.discoveredPlugins = discoveredPlugins
    self.registry = registry
    discoveredIdentifiers = Set(discoveredPlugins.map(\.identifier))
    terminal = RawTerminal()
}
```

- [ ] **Step 2: Update stageSelect to use registry**

Replace line 37:
```swift
let stages = Hook.canonicalOrder.map(\.rawValue)
```
with:
```swift
let stages = registry.executionOrder
```

The `menuItems` and `drawStageScreen` already work with `[String]` so they adapt automatically.

- [ ] **Step 3: Add stage action keys to stageSelect**

In the `stageSelect()` key handling (after `case .char("s")`), add new keybindings:

```swift
case .char("a"):
    addStage()
case .char("u"):
    duplicateStage(at: cursor)
case .char("v"):
    activateStage()
case .char("x"):
    if cursor < stages.count {
        removeStage(stages[cursor])
    }
case .char("n"):
    if cursor < stages.count {
        renameStage(stages[cursor])
    }
case .char("r"):
    if cursor < stages.count, stages.count > 1 {
        if let newPos = reorderStage(startIndex: cursor) {
            cursor = newPos
        }
    }
```

- [ ] **Step 4: Update footer in drawStageScreen**

Update the footer text to include the new keybindings:

```swift
let footerText = footerWithSaveIndicator(
    "\u{2191}\u{2193} navigate  \u{23CE} select  a add  u duplicate  v activate  x remove  n rename  r reorder  s save  Esc quit"
)
```

- [ ] **Step 5: Create ConfigWizard+Stages.swift with CRUD methods**

```swift
// piqley-cli/Sources/piqley/Wizard/ConfigWizard+Stages.swift
import Foundation
import PiqleyCore

extension ConfigWizard {
    func addStage() {
        guard let name = terminal.promptForInput(title: "New stage name") else { return }
        guard StageRegistry.isValidName(name) else {
            terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
            return
        }
        guard !registry.isKnown(name) else {
            terminal.showMessage("Stage '\(name)' already exists.")
            return
        }
        // Choose position
        let positions = registry.active.enumerated().map { "\($0.offset): before \($0.element.name)" }
            + ["\(registry.active.count): at end"]
        guard let posIdx = terminal.selectFromFilterableList(title: "Insert position", items: positions) else { return }
        do {
            try registry.addStage(name, at: posIdx)
            workflow.pipeline[name] = []
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func duplicateStage(at cursor: Int) {
        let stages = registry.executionOrder
        guard cursor < stages.count else { return }
        let sourceName = stages[cursor]
        guard let newName = terminal.promptForInput(title: "Duplicate '\(sourceName)' as") else { return }
        guard StageRegistry.isValidName(newName) else {
            terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
            return
        }
        guard !registry.isKnown(newName) else {
            terminal.showMessage("Stage '\(newName)' already exists.")
            return
        }
        // Copy stage-*.json files for each plugin that has the source stage
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        for plugin in discoveredPlugins where plugin.stages[sourceName] != nil {
            let sourceFile = plugin.directory
                .appendingPathComponent("\(PluginFile.stagePrefix)\(sourceName)\(PluginFile.stageSuffix)")
            let destFile = plugin.directory
                .appendingPathComponent("\(PluginFile.stagePrefix)\(newName)\(PluginFile.stageSuffix)")
            try? FileManager.default.copyItem(at: sourceFile, to: destFile)
        }
        do {
            try registry.addStage(newName, at: cursor + 1)
            workflow.pipeline[newName] = []
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func activateStage() {
        guard !registry.available.isEmpty else {
            terminal.showMessage("No available stages to activate.")
            return
        }
        let items = registry.available.map(\.name)
        guard let idx = terminal.selectFromFilterableList(title: "Activate stage", items: items) else { return }
        let name = items[idx]
        // Choose position
        let positions = registry.active.enumerated().map { "\($0.offset): before \($0.element.name)" }
            + ["\(registry.active.count): at end"]
        guard let posIdx = terminal.selectFromFilterableList(title: "Insert position", items: positions) else { return }
        do {
            try registry.activate(name, at: posIdx)
            if workflow.pipeline[name] == nil {
                workflow.pipeline[name] = []
            }
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func removeStage(_ name: String) {
        do {
            try registry.deactivate(name)
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func renameStage(_ oldName: String) {
        guard let newName = terminal.promptForInput(title: "Rename '\(oldName)' to") else { return }
        guard StageRegistry.isValidName(newName) else {
            terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
            return
        }
        do {
            // Rename stage files first (before mutating registry) so partial failure
            // doesn't leave registry/workflows out of sync with disk
            for plugin in discoveredPlugins {
                let oldFile = plugin.directory
                    .appendingPathComponent("\(PluginFile.stagePrefix)\(oldName)\(PluginFile.stageSuffix)")
                let newFile = plugin.directory
                    .appendingPathComponent("\(PluginFile.stagePrefix)\(newName)\(PluginFile.stageSuffix)")
                if FileManager.default.fileExists(atPath: oldFile.path) {
                    try FileManager.default.moveItem(at: oldFile, to: newFile)
                }
            }
            // Now safe to mutate registry and workflows
            try registry.renameStage(oldName, to: newName)
            // Update current workflow pipeline key
            if let plugins = workflow.pipeline.removeValue(forKey: oldName) {
                workflow.pipeline[newName] = plugins
            }
            // Rename in all other workflows
            let allWorkflowNames = (try? WorkflowStore.list()) ?? []
            for wfName in allWorkflowNames where wfName != workflow.name {
                guard var wf = try? WorkflowStore.load(name: wfName) else { continue }
                if let plugins = wf.pipeline.removeValue(forKey: oldName) {
                    wf.pipeline[newName] = plugins
                    try? WorkflowStore.save(wf)
                }
            }
            modified = true
        } catch {
            terminal.showMessage("Error: \(error)")
        }
    }

    func reorderStage(startIndex: Int) -> Int? {
        var position = startIndex
        let originalActive = registry.active
        let count = originalActive.count

        while true {
            let stages = registry.executionOrder
            let items: [String] = stages.enumerated().map { idx, stage in
                if idx == position {
                    return "  \(ANSI.italic)\(stage)\(ANSI.reset)"
                }
                return stage
            }

            terminal.drawScreen(
                title: "Reorder stages",
                items: items,
                cursor: position,
                footer: "\u{2191}\u{2193} move  \u{23CE} confirm  Esc cancel"
            )

            let key = terminal.readKey()
            switch key {
            case .cursorUp:
                if position > 0 {
                    registry.active.swapAt(position, position - 1)
                    position -= 1
                }
            case .cursorDown:
                if position < count - 1 {
                    registry.active.swapAt(position, position + 1)
                    position += 1
                }
            case .enter:
                if position != startIndex { modified = true }
                return position
            case .escape:
                registry.active = originalActive
                return nil
            default: break
            }
        }
    }
}
```

- [ ] **Step 6: Update ConfigWizard save to persist registry**

In `ConfigWizard.save()`, add registry persistence:

```swift
private func save() {
    applyRemovals()
    do {
        try WorkflowStore.save(workflow)
        let stagesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.stages)
        try registry.save(to: stagesDir)
        modified = false
        savedAt = Date()
    } catch {
        terminal.showMessage("Error saving: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 7: Update all ConfigWizard construction sites**

Search for `ConfigWizard(workflow:` and add `registry:` parameter. Main sites:
- `WorkflowCommand.EditSubcommand.run()`
- `WorkflowCommand.CreateSubcommand.run()`
- `WorkflowListWizard` (check if it creates ConfigWizard)

- [ ] **Step 8: Build and verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 9: Commit**

Message: `feat: add stage CRUD operations to ConfigWizard TUI`

---

### Task 9: Update Existing Tests

**Files:**
- Modify: `piqley-cli/Tests/piqleyTests/PipelineOrchestratorTests.swift`
- Modify: `piqley-cli/Tests/piqleyTests/ConfigTests.swift` (if it references Hook for workflow creation)

- [ ] **Step 1: Update PipelineOrchestratorTests**

The test helper `makePluginsDir` creates stage files. The orchestrator now needs a registry. Add a helper:

```swift
private func makeRegistry(hooks: [String]) -> StageRegistry {
    StageRegistry(
        active: hooks.map { StageEntry(name: $0) },
        available: []
    )
}
```

Update each test that creates a `PipelineOrchestrator` to pass a registry:

```swift
let registry = makeRegistry(hooks: ["pre-process"]) // or whichever hooks the test uses
let orchestrator = PipelineOrchestrator(
    workflow: workflow,
    pluginsDirectory: pluginsDir,
    secretStore: FakeSecretStore(),
    registry: registry
)
```

- [ ] **Step 2: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Commit**

Message: `test: update existing tests to use StageRegistry`

---

### Task 10: Clean Up Hook Enum References

**Files:**
- Modify: `piqley-cli/Sources/piqley/Wizard/ConfigWizard+Plugins.swift` (any remaining Hook references)
- Audit all files for remaining `Hook.canonicalOrder` or `Hook.allCases` usage outside of `StageRegistry` seeding

- [ ] **Step 1: Search for remaining Hook references in CLI**

Run: `grep -rn "Hook\." piqley-cli/Sources/ --include="*.swift"` and identify any that need updating. The only remaining reference to `Hook` should be in `StageRegistry.load` (for seeding defaults) and the `Hook` enum itself.

- [ ] **Step 2: Update ConfigWizard+Plugins.swift**

Line 315 uses `Hook.canonicalOrder` to display a plugin's stages. Update to use the registry's known names instead:

```swift
let stageNames = registry.executionOrder.filter { plugin.stages.keys.contains($0) }
```

Also check `addPlugin` filtering (line 196) which filters by `$0.stages[stageName] != nil`, which already works with any string key.

- [ ] **Step 3: Update any remaining references**

Fix any other files found in the grep search.

- [ ] **Step 4: Build and run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build && swift test 2>&1 | tail -20`
Expected: Build and tests pass

- [ ] **Step 5: Commit**

Message: `refactor: remove remaining Hook enum references outside of registry seeding`
