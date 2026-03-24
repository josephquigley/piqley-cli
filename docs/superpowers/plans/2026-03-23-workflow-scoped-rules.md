# Workflow-Scoped Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move rule storage from plugin directories to workflow directories, making plugins immutable after install.

**Architecture:** Workflows become directories (`{name}/workflow.json` + `rules/{pluginID}/stage-*.json`). Plugin stage files are copied into the workflow on plugin-add (seed on add). All runtime rule reads go through the workflow rules dir. Stage operations are workflow-scoped.

**Tech Stack:** Swift 6, Swift Testing framework, PiqleyCore, ArgumentParser

**Spec:** `docs/superpowers/specs/2026-03-23-workflow-scoped-rules-design.md`

---

## Task Order

Tasks are sequential. Each builds on the previous.

---

### Task 1: Update WorkflowStore to directory-based layout

**Files:**
- Modify: `Sources/piqley/Config/WorkflowStore.swift`
- Test: `Tests/piqleyTests/WorkflowStoreTests.swift` (create)

- [ ] **Step 1: Write failing tests for directory-based WorkflowStore**

```swift
import Foundation
import PiqleyCore
import Testing
@testable import piqley

@Suite("WorkflowStore")
struct WorkflowStoreTests {
    let testDir: URL

    init() throws {
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-wf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    @Test("directoryURL returns workflow-name subdirectory")
    func directoryURL() {
        let url = WorkflowStore.directoryURL(name: "default", root: testDir)
        #expect(url.lastPathComponent == "default")
    }

    @Test("fileURL returns workflow.json inside directory")
    func fileURL() {
        let url = WorkflowStore.fileURL(name: "default", root: testDir)
        #expect(url.lastPathComponent == "workflow.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "default")
    }

    @Test("rulesDirectory returns rules/ inside workflow directory")
    func rulesDirectory() {
        let url = WorkflowStore.rulesDirectory(name: "default", root: testDir)
        #expect(url.lastPathComponent == "rules")
        #expect(url.deletingLastPathComponent().lastPathComponent == "default")
    }

    @Test("save creates directory and workflow.json")
    func saveCreatesDirectory() throws {
        let workflow = Workflow(name: "test", displayName: "Test", description: "A test workflow")
        try WorkflowStore.save(workflow, root: testDir)

        let dirExists = FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("test").path
        )
        #expect(dirExists)

        let fileExists = FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("test/workflow.json").path
        )
        #expect(fileExists)
    }

    @Test("load reads from directory layout")
    func loadFromDirectory() throws {
        let workflow = Workflow(name: "roundtrip", displayName: "RT", description: "desc")
        try WorkflowStore.save(workflow, root: testDir)

        let loaded = try WorkflowStore.load(name: "roundtrip", root: testDir)
        #expect(loaded.name == "roundtrip")
        #expect(loaded.displayName == "RT")
    }

    @Test("list returns workflow directory names")
    func listWorkflows() throws {
        try WorkflowStore.save(
            Workflow(name: "alpha", displayName: "Alpha", description: ""),
            root: testDir
        )
        try WorkflowStore.save(
            Workflow(name: "beta", displayName: "Beta", description: ""),
            root: testDir
        )
        let names = try WorkflowStore.list(root: testDir)
        #expect(names == ["alpha", "beta"])
    }

    @Test("delete removes entire workflow directory")
    func deleteWorkflow() throws {
        try WorkflowStore.save(
            Workflow(name: "doomed", displayName: "Doomed", description: ""),
            root: testDir
        )
        try WorkflowStore.delete(name: "doomed", root: testDir)
        let exists = FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("doomed").path
        )
        #expect(!exists)
    }

    @Test("clone deep-copies directory including rules")
    func cloneDeepCopies() throws {
        try WorkflowStore.save(
            Workflow(name: "src", displayName: "Source", description: ""),
            root: testDir
        )
        // Create a rules file in source
        let rulesDir = testDir.appendingPathComponent("src/rules/my.plugin")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: rulesDir.appendingPathComponent("stage-publish.json"))

        try WorkflowStore.clone(source: "src", destination: "dst", root: testDir)

        // Verify workflow.json exists with new name
        let loaded = try WorkflowStore.load(name: "dst", root: testDir)
        #expect(loaded.name == "dst")

        // Verify rules were deep-copied
        let copiedRule = testDir.appendingPathComponent("dst/rules/my.plugin/stage-publish.json")
        #expect(FileManager.default.fileExists(atPath: copiedRule.path))
    }

    @Test("exists checks for workflow directory")
    func existsCheck() throws {
        #expect(!WorkflowStore.exists(name: "nope", root: testDir))
        try WorkflowStore.save(
            Workflow(name: "yep", displayName: "Yep", description: ""),
            root: testDir
        )
        #expect(WorkflowStore.exists(name: "yep", root: testDir))
    }

    @Test("seedDefault creates default workflow when none exist")
    func seedDefault() throws {
        try WorkflowStore.seedDefault(activeStages: ["pre-process", "publish"], root: testDir)
        let names = try WorkflowStore.list(root: testDir)
        #expect(names == ["default"])
        let wf = try WorkflowStore.load(name: "default", root: testDir)
        #expect(wf.pipeline.keys.sorted() == ["pre-process", "publish"])
    }

    @Test("seedDefault does not overwrite existing workflows")
    func seedDefaultNoOverwrite() throws {
        try WorkflowStore.save(
            Workflow(name: "custom", displayName: "Custom", description: ""),
            root: testDir
        )
        try WorkflowStore.seedDefault(activeStages: ["publish"], root: testDir)
        let names = try WorkflowStore.list(root: testDir)
        #expect(names == ["custom"]) // No "default" added
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorkflowStoreTests 2>&1 | head -40`
Expected: compilation errors (methods don't accept `root:` parameter yet)

- [ ] **Step 3: Rewrite WorkflowStore for directory-based layout**

Replace `Sources/piqley/Config/WorkflowStore.swift` with:

```swift
import Foundation

enum WorkflowStore {
    static var workflowsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.workflows)
    }

    static func ensureDirectory(root: URL? = nil) throws {
        let dir = root ?? workflowsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func directoryURL(name: String, root: URL? = nil) -> URL {
        (root ?? workflowsDirectory).appendingPathComponent(name)
    }

    static func fileURL(name: String, root: URL? = nil) -> URL {
        directoryURL(name: name, root: root).appendingPathComponent("workflow.json")
    }

    static func rulesDirectory(name: String, root: URL? = nil) -> URL {
        directoryURL(name: name, root: root).appendingPathComponent("rules")
    }

    static func pluginRulesDirectory(workflowName: String, pluginIdentifier: String, root: URL? = nil) -> URL {
        rulesDirectory(name: workflowName, root: root).appendingPathComponent(pluginIdentifier)
    }

    static func exists(name: String, root: URL? = nil) -> Bool {
        let dir = directoryURL(name: name, root: root)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func list(root: URL? = nil) throws -> [String] {
        let dir = root ?? workflowsDirectory
        try ensureDirectory(root: root)
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("workflow.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    static func load(name: String, root: URL? = nil) throws -> Workflow {
        let data = try Data(contentsOf: fileURL(name: name, root: root))
        return try JSONDecoder().decode(Workflow.self, from: data)
    }

    static func loadAll(root: URL? = nil) throws -> [Workflow] {
        try list(root: root).map { try load(name: $0, root: root) }
    }

    static func save(_ workflow: Workflow, root: URL? = nil) throws {
        let dir = directoryURL(name: workflow.name, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workflow)
        try data.write(to: fileURL(name: workflow.name, root: root))
    }

    static func delete(name: String, root: URL? = nil) throws {
        let dir = directoryURL(name: name, root: root)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw WorkflowError.notFound(name)
        }
        try FileManager.default.removeItem(at: dir)
    }

    static func clone(source: String, destination: String, root: URL? = nil) throws {
        guard exists(name: source, root: root) else {
            throw WorkflowError.notFound(source)
        }
        guard !exists(name: destination, root: root) else {
            throw WorkflowError.alreadyExists(destination)
        }
        // Deep-copy the entire directory (includes rules/)
        let srcDir = directoryURL(name: source, root: root)
        let dstDir = directoryURL(name: destination, root: root)
        try FileManager.default.copyItem(at: srcDir, to: dstDir)

        // Update the workflow.json with new name
        var workflow = try load(name: destination, root: root)
        workflow.name = destination
        workflow.displayName = destination
        try save(workflow, root: root)
    }

    /// Seed the default workflow if no workflows exist.
    static func seedDefault(activeStages: [String], root: URL? = nil) throws {
        try ensureDirectory(root: root)
        let existing = try list(root: root)
        if existing.isEmpty {
            try save(
                .empty(name: "default", displayName: "Default", description: "Default workflow", activeStages: activeStages),
                root: root
            )
        }
    }
}

enum WorkflowError: Error, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)

    var description: String {
        switch self {
        case let .notFound(name): "Workflow '\(name)' not found"
        case let .alreadyExists(name): "Workflow '\(name)' already exists"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorkflowStoreTests 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Fix all callers of WorkflowStore that used the old flat-file API**

Search for all callers: `WorkflowStore.fileURL`, `WorkflowStore.exists`, `WorkflowStore.list`, `WorkflowStore.load`, `WorkflowStore.save`, `WorkflowStore.delete`, `WorkflowStore.clone`, `WorkflowStore.seedDefault`. Update any that passed explicit paths or relied on `.json` file extensions. The new API is source-compatible for callers using default parameters (no `root:` needed).

- [ ] **Step 6: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 7: Commit**

```
feat: convert WorkflowStore to directory-based layout

Workflows are now stored as directories containing workflow.json
and a rules/ subtree, instead of flat JSON files.
```

---

### Task 2: Add rule seeding to ConfigWizard plugin-add

**Files:**
- Modify: `Sources/piqley/Wizard/ConfigWizard.swift` (addPlugin method)
- Modify: `Sources/piqley/Config/WorkflowStore.swift` (add seedRules helper)
- Test: `Tests/piqleyTests/WorkflowStoreTests.swift` (add seeding tests)

- [ ] **Step 1: Write failing test for rule seeding**

Add to `WorkflowStoreTests.swift`:

```swift
@Test("seedRules copies plugin stage files into workflow rules dir")
func seedRulesCopiesStageFiles() throws {
    // Create a workflow
    try WorkflowStore.save(
        Workflow(name: "test", displayName: "Test", description: ""),
        root: testDir
    )

    // Create a fake plugin dir with stage files
    let pluginDir = testDir.appendingPathComponent("plugins/my.plugin")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    let stageData = Data("""
    {"preRules": [{"match": {"field": "original:IPTC:Keywords", "pattern": "test"}, "emit": [], "write": []}]}
    """.utf8)
    try stageData.write(to: pluginDir.appendingPathComponent("stage-publish.json"))
    try stageData.write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))

    // Seed rules
    try WorkflowStore.seedRules(
        workflowName: "test",
        pluginIdentifier: "my.plugin",
        pluginDirectory: pluginDir,
        root: testDir
    )

    // Verify files were copied
    let rulesDir = WorkflowStore.pluginRulesDirectory(
        workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
    )
    let publishExists = FileManager.default.fileExists(
        atPath: rulesDir.appendingPathComponent("stage-publish.json").path
    )
    let preProcessExists = FileManager.default.fileExists(
        atPath: rulesDir.appendingPathComponent("stage-pre-process.json").path
    )
    #expect(publishExists)
    #expect(preProcessExists)
}

@Test("seedRules skips if rules directory already exists")
func seedRulesSkipsExisting() throws {
    try WorkflowStore.save(
        Workflow(name: "test", displayName: "Test", description: ""),
        root: testDir
    )

    // Create plugin dir
    let pluginDir = testDir.appendingPathComponent("plugins/my.plugin")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pluginDir.appendingPathComponent("stage-publish.json"))

    // Pre-create rules dir with custom content
    let rulesDir = WorkflowStore.pluginRulesDirectory(
        workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
    )
    try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
    let customData = Data("{\"custom\": true}".utf8)
    try customData.write(to: rulesDir.appendingPathComponent("stage-publish.json"))

    // Seed rules (should skip)
    try WorkflowStore.seedRules(
        workflowName: "test",
        pluginIdentifier: "my.plugin",
        pluginDirectory: pluginDir,
        root: testDir
    )

    // Verify custom content was preserved
    let data = try Data(contentsOf: rulesDir.appendingPathComponent("stage-publish.json"))
    let str = String(data: data, encoding: .utf8)
    #expect(str?.contains("custom") == true)
}

@Test("removePluginRules deletes the plugin rules directory")
func removePluginRules() throws {
    try WorkflowStore.save(
        Workflow(name: "test", displayName: "Test", description: ""),
        root: testDir
    )
    let rulesDir = WorkflowStore.pluginRulesDirectory(
        workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
    )
    try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: rulesDir.appendingPathComponent("stage-publish.json"))

    try WorkflowStore.removePluginRules(
        workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
    )

    #expect(!FileManager.default.fileExists(atPath: rulesDir.path))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorkflowStoreTests 2>&1 | head -20`
Expected: compilation errors

- [ ] **Step 3: Add seedRules and removePluginRules to WorkflowStore**

Add to `Sources/piqley/Config/WorkflowStore.swift`:

```swift
/// Copy plugin's built-in stage files into the workflow's rules directory.
/// Skips if the plugin already has a rules directory in this workflow (preserves customizations).
static func seedRules(
    workflowName: String,
    pluginIdentifier: String,
    pluginDirectory: URL,
    root: URL? = nil
) throws {
    let destDir = pluginRulesDirectory(
        workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
    )

    // Skip if already seeded (preserves customizations)
    if FileManager.default.fileExists(atPath: destDir.path) { return }

    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    // Copy all stage-*.json files from plugin directory
    let contents = try FileManager.default.contentsOfDirectory(
        at: pluginDirectory, includingPropertiesForKeys: nil
    )
    for file in contents {
        let name = file.lastPathComponent
        guard name.hasPrefix(PluginFile.stagePrefix),
              name.hasSuffix(PluginFile.stageSuffix) else { continue }
        try FileManager.default.copyItem(
            at: file, to: destDir.appendingPathComponent(name)
        )
    }
}

/// Remove all rules for a plugin from a workflow.
static func removePluginRules(
    workflowName: String,
    pluginIdentifier: String,
    root: URL? = nil
) throws {
    let dir = pluginRulesDirectory(
        workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
    )
    if FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.removeItem(at: dir)
    }
}
```

- [ ] **Step 4: Update ConfigWizard.addPlugin to seed rules**

In `Sources/piqley/Wizard/ConfigWizard.swift`, update `addPlugin(stageName:)`. After `workflow.pipeline[stageName] = list`, add rule seeding. The ConfigWizard needs access to `pluginsDirectory`. Add a `pluginsDirectory` property to ConfigWizard's init:

```swift
// In ConfigWizard init, add:
let pluginsDirectory: URL

init(workflow: Workflow, discoveredPlugins: [LoadedPlugin], registry: StageRegistry, pluginsDirectory: URL = PipelineOrchestrator.defaultPluginsDirectory) {
    // ... existing init code ...
    self.pluginsDirectory = pluginsDirectory
}
```

Then in `addPlugin(stageName:)`, after appending to the pipeline list:

```swift
// Seed rules for this plugin if not already seeded
let pluginDir = pluginsDirectory.appendingPathComponent(available[idx])
try? WorkflowStore.seedRules(
    workflowName: workflow.name,
    pluginIdentifier: available[idx],
    pluginDirectory: pluginDir
)
```

- [ ] **Step 5: Update ConfigWizard.applyRemovals to clean up rules**

In `Sources/piqley/Wizard/ConfigWizard.swift`, update `applyRemovals()`. After removing from pipeline, check if the plugin is no longer in any stage. If so, remove its rules:

```swift
private func applyRemovals() {
    var removedIdentifiers: Set<String> = []
    for key in removedPlugins {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let stage = String(parts[0])
        let plugin = String(parts[1])
        workflow.pipeline[stage]?.removeAll { $0 == plugin }
        removedIdentifiers.insert(plugin)
    }
    removedPlugins.removeAll()

    // Clean up rules for plugins no longer in any stage
    let allPipelinePlugins = Set(workflow.pipeline.values.flatMap(\.self))
    for identifier in removedIdentifiers where !allPipelinePlugins.contains(identifier) {
        try? WorkflowStore.removePluginRules(
            workflowName: workflow.name, pluginIdentifier: identifier
        )
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter WorkflowStoreTests 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 7: Commit**

```
feat: add rule seeding on plugin-add and cleanup on plugin-remove
```

---

### Task 3: Redirect StageFileManager and RulesWizard to workflow rules dir

**Files:**
- Modify: `Sources/piqley/Wizard/RulesWizard.swift`
- Modify: `Sources/piqley/Wizard/RulesWizard+UI.swift`
- Modify: `Sources/piqley/CLI/PluginRulesCommand.swift`

- [ ] **Step 1: Rename RulesWizard.pluginDir to rulesDir**

In `Sources/piqley/Wizard/RulesWizard.swift`, rename the stored property:

```swift
// Change:
let pluginDir: URL
// To:
let rulesDir: URL
```

Update the init:

```swift
init(context: RuleEditingContext, rulesDir: URL, dependencyIdentifiers: Set<String> = []) {
    self.context = context
    self.rulesDir = rulesDir
    self.dependencyIdentifiers = dependencyIdentifiers
    terminal = RawTerminal()
}
```

- [ ] **Step 2: Update RulesWizard+UI.swift save() and quit() to use rulesDir**

In `Sources/piqley/Wizard/RulesWizard+UI.swift`:

```swift
// In save():
try StageFileManager.saveStages(context.stages, to: rulesDir)

// In quit():
StageFileManager.cleanupEmptyStageFiles(stages: context.stages, pluginDir: rulesDir)
```

- [ ] **Step 3: Update PluginRulesCommand to resolve workflow and pass rulesDir**

Replace `Sources/piqley/CLI/PluginRulesCommand.swift`:

```swift
import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct PluginRulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Interactively edit rules for a plugin within a workflow."
    )

    @Argument(help: "The plugin identifier (or workflow name if two arguments given).")
    var firstArg: String

    @Argument(help: "The plugin identifier when first argument is a workflow name.")
    var secondArg: String?

    func run() throws {
        let (workflowName, pluginID) = try resolveArguments()

        // Load workflow
        let workflow = try WorkflowStore.load(name: workflowName)

        // Verify plugin is in the workflow's pipeline
        let pipelinePlugins = Set(workflow.pipeline.values.flatMap(\.self))
        guard pipelinePlugins.contains(pluginID) else {
            throw CleanError("Plugin '\(pluginID)' is not in workflow '\(workflowName)'")
        }

        // Resolve plugin directory (for manifest/dependencies only)
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw CleanError("Plugin '\(pluginID)' not found at \(pluginDir.path)")
        }

        // Load manifest
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        // Load stages from workflow rules dir (not plugin dir)
        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginID
        )
        let stagesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.stages)
        let registry = try StageRegistry.load(from: stagesDir)
        let knownHooks = registry.allKnownNames
        var (stages, _) = PluginDiscovery.loadStages(
            from: rulesDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.rules")
        )

        // Ensure all active stages are present (in-memory only)
        for stageName in registry.executionOrder where stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Build field info from all installed plugins
        var deps: [FieldDiscovery.DependencyInfo] = []
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in pluginDirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let mURL = dir.appendingPathComponent(PluginFile.manifest)
                if let data = try? Data(contentsOf: mURL),
                   let pluginManifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
                {
                    let fields = pluginManifest.valueEntries.map(\.key)
                    if !fields.isEmpty {
                        deps.append(FieldDiscovery.DependencyInfo(
                            identifier: pluginManifest.identifier,
                            fields: fields
                        ))
                    }
                }
            }
        }

        // Build context and launch wizard
        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: pluginID,
            stages: stages
        )

        let dependencyIDs = Set(manifest.dependencyIdentifiers)
        let wizard = RulesWizard(context: context, rulesDir: rulesDir, dependencyIdentifiers: dependencyIDs)
        try wizard.run()
    }

    private func resolveArguments() throws -> (workflowName: String, pluginID: String) {
        if let pluginID = secondArg {
            // Explicit: piqley rules <workflow> <plugin>
            return (firstArg, pluginID)
        }

        // Single arg: check if it's a plugin identifier
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        let isPlugin = FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent(firstArg).path
        )

        if isPlugin {
            // Fallback to sole workflow
            let workflows = try WorkflowStore.list()
            guard workflows.count == 1, let workflowName = workflows.first else {
                throw CleanError(
                    "Multiple workflows exist. Specify the workflow: piqley rules <workflow> \(firstArg)"
                )
            }
            return (workflowName, firstArg)
        }

        throw CleanError(
            "Plugin '\(firstArg)' not found. Usage: piqley rules [workflow] <plugin>"
        )
    }
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: Builds successfully

- [ ] **Step 5: Commit**

```
feat: redirect RulesWizard to read/write workflow rules directory

PluginRulesCommand now resolves a workflow context. Single-arg usage
falls back to the sole workflow when only one exists.
```

---

### Task 4: Scope stage operations to current workflow

**Files:**
- Modify: `Sources/piqley/Wizard/ConfigWizard+Stages.swift`
- Modify: `Sources/piqley/Wizard/ConfigWizard.swift`

- [ ] **Step 1: Update removeStage to delete stage files from workflow rules**

In `Sources/piqley/Wizard/ConfigWizard+Stages.swift`, replace `removeStage`:

```swift
func removeStage(_ name: String) {
    do {
        try registry.deactivate(name)
        workflow.pipeline.removeValue(forKey: name)

        // Delete stage files from all plugin rules dirs in this workflow
        let rulesDir = WorkflowStore.rulesDirectory(name: workflow.name)
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for pluginDir in pluginDirs {
                let stageFile = pluginDir.appendingPathComponent(
                    "\(PluginFile.stagePrefix)\(name)\(PluginFile.stageSuffix)"
                )
                if FileManager.default.fileExists(atPath: stageFile.path) {
                    try FileManager.default.removeItem(at: stageFile)
                }
            }
        }

        modified = true
    } catch {
        terminal.showMessage("Error: \(error)")
    }
}
```

- [ ] **Step 2: Update renameStage to operate on workflow rules only**

Replace `renameStage` in `ConfigWizard+Stages.swift`:

```swift
func renameStage(_ oldName: String) {
    guard let newName = terminal.promptForInput(title: "Rename '\(oldName)' to", hint: "lowercase-with-hyphens") else { return }
    guard StageRegistry.isValidName(newName) else {
        terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
        return
    }
    do {
        // Rename stage files in this workflow's rules dir
        let rulesDir = WorkflowStore.rulesDirectory(name: workflow.name)
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for pluginDir in pluginDirs {
                let oldFile = pluginDir.appendingPathComponent(
                    "\(PluginFile.stagePrefix)\(oldName)\(PluginFile.stageSuffix)"
                )
                let newFile = pluginDir.appendingPathComponent(
                    "\(PluginFile.stagePrefix)\(newName)\(PluginFile.stageSuffix)"
                )
                if FileManager.default.fileExists(atPath: oldFile.path) {
                    try FileManager.default.moveItem(at: oldFile, to: newFile)
                }
            }
        }

        // Update global registry
        try registry.renameStage(oldName, to: newName)

        // Update this workflow's pipeline
        if let plugins = workflow.pipeline.removeValue(forKey: oldName) {
            workflow.pipeline[newName] = plugins
        }

        modified = true
    } catch {
        terminal.showMessage("Error: \(error)")
    }
}
```

- [ ] **Step 3: Update duplicateStage to operate on workflow rules only**

Replace `duplicateStage` in `ConfigWizard+Stages.swift`:

```swift
func duplicateStage(at cursor: Int) {
    let stages = registry.executionOrder
    guard cursor < stages.count else { return }
    let sourceName = stages[cursor]
    guard let newName = terminal.promptForInput(title: "Duplicate '\(sourceName)' as", hint: "lowercase-with-hyphens") else { return }
    guard StageRegistry.isValidName(newName) else {
        terminal.showMessage("Invalid name. Use lowercase alphanumeric and hyphens (min 2 chars).")
        return
    }
    guard !registry.isKnown(newName) else {
        terminal.showMessage("Stage '\(newName)' already exists.")
        return
    }
    // Copy stage files in this workflow's rules dir
    let rulesDir = WorkflowStore.rulesDirectory(name: workflow.name)
    if let pluginDirs = try? FileManager.default.contentsOfDirectory(
        at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
    ) {
        for pluginDir in pluginDirs {
            let sourceFile = pluginDir.appendingPathComponent(
                "\(PluginFile.stagePrefix)\(sourceName)\(PluginFile.stageSuffix)"
            )
            let destFile = pluginDir.appendingPathComponent(
                "\(PluginFile.stagePrefix)\(newName)\(PluginFile.stageSuffix)"
            )
            if FileManager.default.fileExists(atPath: sourceFile.path) {
                try? FileManager.default.copyItem(at: sourceFile, to: destFile)
            }
        }
    }
    do {
        try registry.addStage(newName, at: cursor + 1)
        workflow.pipeline[newName] = workflow.pipeline[sourceName] ?? []
        modified = true
    } catch {
        terminal.showMessage("Error: \(error)")
    }
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: Builds successfully

- [ ] **Step 5: Commit**

```
refactor: scope stage operations to current workflow rules directory

Stage rename, duplicate, and remove now operate on workflow rules dirs
instead of plugin directories. No cross-workflow side effects.
```

---

### Task 5: Update PipelineOrchestrator to load rules from workflow

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`
- Modify: `Sources/piqley/Plugins/PluginDiscovery.swift`

- [ ] **Step 1: Update loadPlugin to accept a workflow rules path**

In `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`, update `loadPlugin`:

```swift
func loadPlugin(named identifier: String) throws -> LoadedPlugin? {
    let pluginDir = pluginsDirectory.appendingPathComponent(identifier)
    let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

    // Load stages from workflow rules dir instead of plugin dir
    let rulesDir = WorkflowStore.pluginRulesDirectory(
        workflowName: workflow.name, pluginIdentifier: identifier
    )
    let knownHooks = registry.allKnownNames
    let (stages, _) = PluginDiscovery.loadStages(from: rulesDir, knownHooks: knownHooks, logger: logger)

    return LoadedPlugin(
        identifier: manifest.identifier, name: manifest.name,
        directory: pluginDir, manifest: manifest, stages: stages
    )
}
```

- [ ] **Step 2: Relax noStageFiles validation in PluginDiscovery.loadManifests**

In `Sources/piqley/Plugins/PluginDiscovery.swift`, remove the `noStageFiles` throw from `loadManifests()`. This validation was for install-time. At runtime, stages come from workflow rules. Change lines 80-86:

```swift
// Remove this block:
// if stages.isEmpty {
//     throw PluginDiscoveryError.noStageFiles(
//         plugin: manifest.identifier,
//         path: url.path
//     )
// }
```

The `loadManifests()` method is used by ConfigWizard for plugin discovery, where having no stage files is now valid (the plugin's rules live in the workflow).

- [ ] **Step 3: Build and run full test suite**

Run: `swift build 2>&1 | tail -10 && swift test 2>&1 | tail -20`
Expected: Build succeeds, all tests pass

- [ ] **Step 4: Update PluginDiscoveryTests if any relied on noStageFiles error**

Check `Tests/piqleyTests/PluginDiscoveryTests.swift` for tests that assert `noStageFiles`. Update or remove them.

- [ ] **Step 5: Commit**

```
feat: load rules from workflow directory at runtime

PipelineOrchestrator now reads stage configs from the workflow's
rules directory instead of the plugin directory. Plugins are
immutable after install.
```

---

### Task 6: Update ConfigWizard addPlugin filter and callers

**Files:**
- Modify: `Sources/piqley/Wizard/ConfigWizard.swift`
- Modify: `Sources/piqley/CLI/SetupCommand.swift`
- Modify: `Sources/piqley/CLI/WorkflowCommand.swift`

- [ ] **Step 1: Update addPlugin to not filter by stage**

Currently `addPlugin` filters available plugins by `$0.stages[stageName] != nil`. Since rules now live in the workflow, a plugin might not have a stage file for every stage in the plugin dir. Instead, allow adding any installed plugin and seed rules on add. Update the filter in `addPlugin`:

```swift
private func addPlugin(stageName: String) {
    let currentPlugins = Set(workflow.pipeline[stageName] ?? [])
    let available = discoveredPlugins
        .filter { !currentPlugins.contains($0.identifier) }
        .map(\.identifier)
        .sorted()

    if available.isEmpty {
        terminal.showMessage("No plugins available to add.")
        return
    }

    guard let idx = terminal.selectFromFilterableList(title: "Add plugin to \(stageName)", items: available) else {
        return
    }

    var list = workflow.pipeline[stageName] ?? []
    list.append(available[idx])
    workflow.pipeline[stageName] = list

    // Seed rules for this plugin if not already seeded
    let pluginDir = pluginsDirectory.appendingPathComponent(available[idx])
    try? WorkflowStore.seedRules(
        workflowName: workflow.name,
        pluginIdentifier: available[idx],
        pluginDirectory: pluginDir
    )

    modified = true
}
```

- [ ] **Step 2: Update all ConfigWizard callers to pass pluginsDirectory**

In `Sources/piqley/CLI/SetupCommand.swift` and `Sources/piqley/CLI/WorkflowCommand.swift`, update `ConfigWizard(...)` calls to include `pluginsDirectory:` if the new init requires it. Since the default is `PipelineOrchestrator.defaultPluginsDirectory`, existing callers compile without changes.

- [ ] **Step 3: Build and test**

Run: `swift build 2>&1 | tail -10 && swift test 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 4: Commit**

```
refactor: allow adding any plugin to any stage and seed rules on add
```

---

### Task 7: Clean up old flat-file workflow artifacts

**Files:**
- Modify: `Sources/piqley/CLI/PluginUninstallCommand.swift` (if it touches plugin stage files)
- Run through codebase for any remaining plugin-dir writes

- [ ] **Step 1: Search for remaining plugin directory writes**

Search the codebase for any remaining code that writes to plugin directories (excluding install/uninstall):

Run: `grep -rn "pluginDir\|plugin.directory\|PluginFile.stagePrefix" Sources/piqley/ --include="*.swift" | grep -v "PluginDiscovery\|StageFileManager\|InstallCommand\|PluginUninstallCommand\|PluginRulesCommand"`

Fix any remaining references.

- [ ] **Step 2: Update PluginUninstallCommand to clean up workflow rules**

In the uninstall flow, after removing a plugin from workflows, also clean up the rules directories:

```swift
// After removing from workflow pipelines, also remove rules
for workflowName in try WorkflowStore.list() {
    try? WorkflowStore.removePluginRules(
        workflowName: workflowName, pluginIdentifier: pluginIdentifier
    )
}
```

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 4: Commit**

```
refactor: remove all post-install plugin directory writes

Plugins are now fully immutable after installation. Uninstall
cleans up workflow rules directories.
```

---

### Task 8: Final integration verification

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 2: Build release**

Run: `swift build -c release 2>&1 | tail -10`
Expected: Clean build

- [ ] **Step 3: Commit any remaining fixes**

If any tests or build issues were found, commit the fixes.
