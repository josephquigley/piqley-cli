# Command Editor Workflow Scoping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `piqley plugin command` to load/save stage files from the workflow rules directory instead of the plugin directory, and share argument resolution logic with `piqley plugin rules`.

**Architecture:** Extract the workflow+plugin argument resolution from `PluginRulesCommand` into a shared `PluginWorkflowResolver`. Update `PluginCommandEditCommand` and `CommandEditWizard` to use workflow-scoped stage directories.

**Tech Stack:** Swift, ArgumentParser, Swift Testing

---

### Task 1: Create `PluginWorkflowResolver`

**Files:**
- Create: `Sources/piqley/CLI/PluginWorkflowResolver.swift`
- Test: `Tests/piqleyTests/PluginWorkflowResolverTests.swift`

- [ ] **Step 1: Write tests for the resolver**

```swift
import Foundation
import PiqleyCore
import Testing
@testable import piqley

@Suite("PluginWorkflowResolver")
struct PluginWorkflowResolverTests {
    let testDir: URL
    let pluginsDir: URL

    init() throws {
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-resolver-\(UUID().uuidString)")
        pluginsDir = testDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    }

    private func createWorkflow(name: String, plugins: [String: [String]]) throws {
        let workflow = Workflow(name: name, displayName: name, description: "")
        var wf = workflow
        wf.pipeline = plugins
        try WorkflowStore.save(wf, root: testDir)
    }

    private func createPlugin(id: String) throws {
        let dir = pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            identifier: id, name: id, pluginVersion: "0.0.1", pluginSchemaVersion: "1"
        )
        let data = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
        try data.write(to: dir.appendingPathComponent(PluginFile.manifest))
    }

    @Test("two args returns workflow and plugin directly")
    func twoArgs() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: "my-workflow", secondArg: "my-plugin",
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID) = try resolver.resolve()
        #expect(workflowName == "my-workflow")
        #expect(pluginID == "my-plugin")
    }

    @Test("single arg that is a plugin with one workflow auto-resolves")
    func singleArgPlugin() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.test.plugin"]])
        try createPlugin(id: "com.test.plugin")

        let resolver = PluginWorkflowResolver(
            firstArg: "com.test.plugin", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID) = try resolver.resolve()
        #expect(workflowName == "wf1")
        #expect(pluginID == "com.test.plugin")
    }

    @Test("single arg that is a workflow with one plugin auto-resolves")
    func singleArgWorkflow() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.test.plugin"]])

        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID) = try resolver.resolve()
        #expect(workflowName == "wf1")
        #expect(pluginID == "com.test.plugin")
    }

    @Test("single arg that is neither workflow nor plugin throws")
    func singleArgUnknown() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: "nonexistent", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }

    @Test("single arg plugin not in any workflow throws")
    func pluginNotInWorkflow() throws {
        try createPlugin(id: "com.orphan.plugin")

        let resolver = PluginWorkflowResolver(
            firstArg: "com.orphan.plugin", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }

    @Test("single arg workflow with no plugins throws")
    func workflowNoPlugins() throws {
        try createWorkflow(name: "empty-wf", plugins: [:])

        let resolver = PluginWorkflowResolver(
            firstArg: "empty-wf", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginWorkflowResolverTests 2>&1 | tail -5`
Expected: Compilation failure (PluginWorkflowResolver not defined)

- [ ] **Step 3: Create `PluginWorkflowResolver`**

```swift
import ArgumentParser
import Foundation
import PiqleyCore

struct PluginWorkflowResolver {
    let firstArg: String?
    let secondArg: String?
    /// Used in non-interactive error messages, e.g. "piqley plugin command <workflow> <plugin>"
    let usageHint: String
    let workflowsRoot: URL?
    let pluginsDirectory: URL

    init(
        firstArg: String?, secondArg: String?,
        usageHint: String,
        workflowsRoot: URL? = nil,
        pluginsDirectory: URL = PipelineOrchestrator.defaultPluginsDirectory
    ) {
        self.firstArg = firstArg
        self.secondArg = secondArg
        self.usageHint = usageHint
        self.workflowsRoot = workflowsRoot
        self.pluginsDirectory = pluginsDirectory
    }

    func resolve() throws -> (workflowName: String, pluginID: String) {
        if let firstArg, let pluginID = secondArg {
            return (firstArg, pluginID)
        }

        if let firstArg {
            return try resolveSingleArg(firstArg)
        }

        return try resolveNoArgs()
    }

    // MARK: - Private

    private func resolveSingleArg(_ arg: String) throws -> (workflowName: String, pluginID: String) {
        if WorkflowStore.exists(name: arg, root: workflowsRoot) {
            let workflow = try WorkflowStore.load(name: arg, root: workflowsRoot)
            let plugins = pipelinePlugins(workflow)
            guard !plugins.isEmpty else {
                throw CleanError("Workflow '\(arg)' has no plugins in its pipeline.")
            }
            if plugins.count == 1 {
                return (arg, plugins[0])
            }
            let pluginID = try selectInteractively(
                title: "Select plugin (\(arg))",
                items: plugins
            )
            return (arg, pluginID)
        }

        let isPlugin = FileManager.default.fileExists(
            atPath: pluginsDirectory.appendingPathComponent(arg).path
        )

        if isPlugin {
            let allWorkflows = try WorkflowStore.loadAll(root: workflowsRoot)
            let matching = allWorkflows.filter { workflow in
                workflow.pipeline.values.flatMap(\.self).contains(arg)
            }
            guard !matching.isEmpty else {
                throw CleanError("Plugin '\(arg)' is not in any workflow's pipeline.")
            }
            if matching.count == 1 {
                return (matching[0].name, arg)
            }
            let workflowName = try selectInteractively(
                title: "Select workflow for '\(arg)'",
                items: matching.map(\.name)
            )
            return (workflowName, arg)
        }

        throw CleanError("'\(arg)' is not a known workflow or installed plugin.")
    }

    private func resolveNoArgs() throws -> (workflowName: String, pluginID: String) {
        let workflowNames = try WorkflowStore.list(root: workflowsRoot)
        guard !workflowNames.isEmpty else {
            throw CleanError("No workflows found. Run 'piqley setup' first.")
        }

        let workflowName: String = if workflowNames.count == 1 {
            workflowNames[0]
        } else {
            try selectInteractively(
                title: "Select workflow",
                items: workflowNames
            )
        }

        let workflow = try WorkflowStore.load(name: workflowName, root: workflowsRoot)
        let plugins = pipelinePlugins(workflow)
        guard !plugins.isEmpty else {
            throw CleanError("Workflow '\(workflowName)' has no plugins in its pipeline.")
        }

        if plugins.count == 1 {
            return (workflowName, plugins[0])
        }

        let pluginID = try selectInteractively(
            title: "Select plugin (\(workflowName))",
            items: plugins
        )
        return (workflowName, pluginID)
    }

    private func pipelinePlugins(_ workflow: Workflow) -> [String] {
        Array(Set(workflow.pipeline.values.flatMap(\.self))).sorted()
    }

    private func selectInteractively(title: String, items: [String]) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CleanError(
                "Multiple options available but stdin is not a terminal. "
                    + "Specify explicitly: \(usageHint) <workflow> <plugin>"
            )
        }
        let terminal = RawTerminal()
        defer { terminal.restore() }
        guard let index = terminal.selectFromList(title: title, items: items) else {
            throw ExitCode.success
        }
        return items[index]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginWorkflowResolverTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

Message: `feat: add PluginWorkflowResolver for shared argument resolution`

---

### Task 2: Refactor `PluginRulesCommand` to use `PluginWorkflowResolver`

**Files:**
- Modify: `Sources/piqley/CLI/PluginRulesCommand.swift`

- [ ] **Step 1: Replace private resolution methods with `PluginWorkflowResolver`**

Replace the entire `// MARK: - Argument Resolution` section and `// MARK: - Helpers` section (lines 89-201) with:

```swift
    // MARK: - Argument Resolution

    private func resolveArguments() throws -> (workflowName: String, pluginID: String) {
        let resolver = PluginWorkflowResolver(
            firstArg: firstArg, secondArg: secondArg,
            usageHint: "piqley plugin rules"
        )
        return try resolver.resolve()
    }
```

The `run()` method and everything above the mark stay unchanged.

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 4: Commit**

Message: `refactor: use PluginWorkflowResolver in PluginRulesCommand`

---

### Task 3: Update `CommandEditWizard` to accept `rulesDir`

**Files:**
- Modify: `Sources/piqley/Wizard/CommandEditWizard.swift`

- [ ] **Step 1: Add `rulesDir` property and update init**

Change the stored properties and init (lines 6-38):

Old:
```swift
final class CommandEditWizard {
    let pluginID: String
    var stages: [String: StageConfig]
    let pluginDir: URL
    let terminal: RawTerminal
```

New:
```swift
final class CommandEditWizard {
    let pluginID: String
    var stages: [String: StageConfig]
    let pluginDir: URL
    let rulesDir: URL
    let terminal: RawTerminal
```

Old init signature:
```swift
    init(
        pluginID: String, stages: [String: StageConfig], pluginDir: URL,
        availableFields: [String: [FieldInfo]] = [:]
    ) {
        self.pluginID = pluginID
        self.stages = stages
        self.pluginDir = pluginDir
        terminal = RawTerminal()
        fieldCompletions = Self.buildFieldCompletions(from: availableFields)
    }
```

New init signature:
```swift
    init(
        pluginID: String, stages: [String: StageConfig], pluginDir: URL,
        rulesDir: URL,
        availableFields: [String: [FieldInfo]] = [:]
    ) {
        self.pluginID = pluginID
        self.stages = stages
        self.pluginDir = pluginDir
        self.rulesDir = rulesDir
        terminal = RawTerminal()
        fieldCompletions = Self.buildFieldCompletions(from: availableFields)
    }
```

- [ ] **Step 2: Update `save()` to write to `rulesDir`**

Old (line 434-442):
```swift
    private func save() {
        do {
            try StageFileManager.saveStages(stages, to: pluginDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }
```

New:
```swift
    private func save() {
        do {
            try StageFileManager.saveStages(stages, to: rulesDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 3: Update `quit()` to clean up `rulesDir`**

Old (line 444-448):
```swift
    private func quit() {
        StageFileManager.cleanupEmptyStageFiles(stages: stages, pluginDir: pluginDir)
        terminal.restore()
        Foundation.exit(0)
    }
```

New:
```swift
    private func quit() {
        StageFileManager.cleanupEmptyStageFiles(stages: stages, pluginDir: rulesDir)
        terminal.restore()
        Foundation.exit(0)
    }
```

- [ ] **Step 4: Update `PluginCommandEditCommand` call site to compile**

Temporarily pass `pluginDir` as `rulesDir` to keep it compiling (will be fixed properly in Task 4):

Old (line 58-61):
```swift
        let wizard = CommandEditWizard(
            pluginID: pluginID, stages: stages, pluginDir: pluginDir,
            availableFields: availableFields
        )
```

New:
```swift
        let wizard = CommandEditWizard(
            pluginID: pluginID, stages: stages, pluginDir: pluginDir,
            rulesDir: pluginDir,
            availableFields: availableFields
        )
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

Message: `refactor: add rulesDir parameter to CommandEditWizard`

---

### Task 4: Update `PluginCommandEditCommand` to use workflow-scoped stages

**Files:**
- Modify: `Sources/piqley/CLI/PluginCommandEditCommand.swift`

- [ ] **Step 1: Rewrite `PluginCommandEditCommand`**

Replace the entire file content:

```swift
import ArgumentParser
import Foundation
import Logging
import PiqleyCore

struct PluginCommandEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "command",
        abstract: "Edit binary command configuration for a plugin's stages within a workflow."
    )

    @Argument(help: "The plugin identifier (or workflow name if two arguments given).")
    var firstArg: String?

    @Argument(help: "The plugin identifier when first argument is a workflow name.")
    var secondArg: String?

    func run() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: firstArg, secondArg: secondArg,
            usageHint: "piqley plugin command"
        )
        let (workflowName, pluginID) = try resolver.resolve()

        // Verify plugin is in the workflow's pipeline
        let workflow = try WorkflowStore.load(name: workflowName)
        let plugins = Set(workflow.pipeline.values.flatMap(\.self))
        guard plugins.contains(pluginID) else {
            throw CleanError("Plugin '\(pluginID)' is not in workflow '\(workflowName)'")
        }

        // Plugin directory for manifest loading and binary probing
        let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
            .appendingPathComponent(pluginID)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw CleanError("Plugin '\(pluginID)' not found at \(pluginDir.path)")
        }

        // Workflow rules directory for stage file I/O
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
            logger: Logger(label: "piqley.command")
        )

        // Ensure all active stages are present (in-memory only, not written to disk)
        for stageName in registry.executionOrder where stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Load manifest and build available fields for env var autocompletion
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)

        // Discover fields from upstream plugins' rules files
        let rulesBaseDir = WorkflowStore.rulesDirectory(name: workflowName)
        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: workflow.pipeline,
            targetPlugin: pluginID,
            stageOrder: registry.executionOrder,
            rulesBaseDir: rulesBaseDir
        )

        // Add the target plugin's own consumed fields
        var allDeps = deps
        if !manifest.consumedFields.isEmpty {
            let ownFields = manifest.consumedFields.map(\.name)
            allDeps.append(FieldDiscovery.DependencyInfo(identifier: pluginID, fields: ownFields))
        }

        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: allDeps)

        let wizard = CommandEditWizard(
            pluginID: pluginID, stages: stages, pluginDir: pluginDir,
            rulesDir: rulesDir,
            availableFields: availableFields
        )
        try wizard.run()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 4: Commit**

Message: `fix: command editor now loads and saves stages from workflow rules directory`
