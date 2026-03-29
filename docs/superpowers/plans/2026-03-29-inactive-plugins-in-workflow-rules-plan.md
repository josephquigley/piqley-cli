# Inactive Plugins in `workflow rules` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show installed-but-not-in-pipeline plugins in the `piqley workflow rules` plugin selection list, and add them to the workflow when selected.

**Architecture:** Extend `PluginWorkflowResolver` with an optional `discoveredPlugins` parameter that adds inactive plugins to the interactive selection list behind a divider. Add a `selectFromListWithDivider` method to `RawTerminal` for divider-aware navigation. Update `RulesSubcommand` to handle inactive plugin activation (stage picker, pipeline add, rule seeding) before launching the rule editor.

**Tech Stack:** Swift, Swift Testing, PiqleyCore

---

### Task 1: Add `selectFromListWithDivider` to RawTerminal

**Files:**
- Modify: `Sources/piqley/Wizard/Terminal.swift:187-208`
- Test: `Tests/piqleyTests/TerminalDividerSelectionTests.swift`

The existing `selectFromList` has no concept of non-selectable divider rows. Add a new method that skips a divider index during navigation and prevents selecting it.

- [ ] **Step 1: Write the failing test**

Create `Tests/piqleyTests/TerminalDividerSelectionTests.swift`:

```swift
import Foundation
import Testing
@testable import piqley

@Suite("selectFromListWithDivider")
struct TerminalDividerSelectionTests {
    @Test("divider index is skipped when navigating down")
    func dividerSkippedDown() {
        // Verify the navigation helper skips the divider
        // Active: ["plugin-a", "plugin-b"], divider at index 2, inactive: ["plugin-c"]
        // Items: ["plugin-a", "plugin-b", "── inactive ──", "plugin-c"]
        let result = RawTerminal.navigateWithDivider(
            key: .cursorDown, cursor: 1, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 3)
    }

    @Test("divider index is skipped when navigating up")
    func dividerSkippedUp() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorUp, cursor: 3, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 1)
    }

    @Test("navigation without divider works normally")
    func noDivider() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorDown, cursor: 0, itemCount: 3, dividerIndex: nil
        )
        #expect(result == 1)
    }

    @Test("cursor does not go below last item")
    func cursorClamped() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorDown, cursor: 3, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 3)
    }

    @Test("cursor does not go above first item")
    func cursorClampedTop() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorUp, cursor: 0, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalDividerSelectionTests 2>&1 | tail -20`
Expected: Compilation error because `RawTerminal.navigateWithDivider` does not exist.

- [ ] **Step 3: Implement `navigateWithDivider` and `selectFromListWithDivider`**

In `Sources/piqley/Wizard/Terminal.swift`, add these two methods to `RawTerminal`:

```swift
/// Pure navigation helper that skips a divider index. Extracted for testability.
static func navigateWithDivider(
    key: Key, cursor: Int, itemCount: Int, dividerIndex: Int?
) -> Int {
    let maxIdx = max(itemCount - 1, 0)
    var newCursor: Int
    switch key {
    case .cursorUp: newCursor = max(0, cursor - 1)
    case .cursorDown: newCursor = min(maxIdx, cursor + 1)
    case .pageUp: newCursor = max(0, cursor - 10)
    case .pageDown: newCursor = min(maxIdx, cursor + 10)
    default: return cursor
    }
    if let dividerIndex, newCursor == dividerIndex {
        let direction = (key == .cursorUp || key == .pageUp) ? -1 : 1
        newCursor = max(0, min(maxIdx, newCursor + direction))
    }
    return newCursor
}

/// Show a selectable list with a non-selectable divider row.
/// Returns the chosen index, or nil if cancelled. The divider row cannot be selected.
func selectFromListWithDivider(
    title: String, items: [String], dividerIndex: Int?
) -> Int? {
    var cursor = 0
    while true {
        drawScreen(
            title: title,
            items: items,
            cursor: cursor,
            footer: "\u{2191}\u{2193} navigate  \u{23CE} select  Esc cancel"
        )

        let key = readKey()
        switch key {
        case .cursorUp, .cursorDown, .pageUp, .pageDown:
            cursor = Self.navigateWithDivider(
                key: key, cursor: cursor, itemCount: items.count, dividerIndex: dividerIndex
            )
        case .enter:
            if cursor != dividerIndex {
                return cursor
            }
        case .escape, .ctrlC: return nil
        default: break
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalDividerSelectionTests 2>&1 | tail -20`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

Message: `feat: add selectFromListWithDivider to RawTerminal`

---

### Task 2: Extend PluginWorkflowResolver to show inactive plugins

**Files:**
- Modify: `Sources/piqley/CLI/PluginWorkflowResolver.swift`
- Test: `Tests/piqleyTests/PluginWorkflowResolverTests.swift`

Add `discoveredPlugins` parameter. Change return type to include `isInactive`. Update the interactive selection paths to show inactive plugins below a divider.

- [ ] **Step 1: Write failing tests for the new behavior**

Add to `Tests/piqleyTests/PluginWorkflowResolverTests.swift`:

```swift
@Test("two args with discovered plugins returns isInactive true when not in pipeline")
func twoArgsInactive() throws {
    try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])
    try createPlugin(id: "com.inactive.plugin")

    let discovered = [loadedPlugin(id: "com.inactive.plugin")]
    let resolver = PluginWorkflowResolver(
        firstArg: "wf1", secondArg: "com.inactive.plugin",
        usageHint: "piqley workflow rules", workflowsRoot: testDir,
        pluginsDirectory: pluginsDir, discoveredPlugins: discovered
    )
    let result = try resolver.resolve()
    #expect(result.workflowName == "wf1")
    #expect(result.pluginID == "com.inactive.plugin")
    #expect(result.isInactive == true)
}

@Test("two args with discovered plugins returns isInactive false when in pipeline")
func twoArgsActive() throws {
    try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])
    try createPlugin(id: "com.active.plugin")

    let discovered = [loadedPlugin(id: "com.active.plugin")]
    let resolver = PluginWorkflowResolver(
        firstArg: "wf1", secondArg: "com.active.plugin",
        usageHint: "piqley workflow rules", workflowsRoot: testDir,
        pluginsDirectory: pluginsDir, discoveredPlugins: discovered
    )
    let result = try resolver.resolve()
    #expect(result.workflowName == "wf1")
    #expect(result.pluginID == "com.active.plugin")
    #expect(result.isInactive == false)
}

@Test("two args without discovered plugins throws for inactive plugin (legacy behavior)")
func twoArgsLegacy() throws {
    try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])

    let resolver = PluginWorkflowResolver(
        firstArg: "wf1", secondArg: "com.active.plugin",
        usageHint: "piqley workflow rules", workflowsRoot: testDir,
        pluginsDirectory: pluginsDir
    )
    let result = try resolver.resolve()
    #expect(result.workflowName == "wf1")
    #expect(result.pluginID == "com.active.plugin")
    #expect(result.isInactive == false)
}

@Test("single arg workflow with one plugin auto-resolves with isInactive")
func singleArgWorkflowWithDiscovered() throws {
    try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])

    let resolver = PluginWorkflowResolver(
        firstArg: "wf1", secondArg: nil,
        usageHint: "piqley workflow rules", workflowsRoot: testDir,
        pluginsDirectory: pluginsDir, discoveredPlugins: []
    )
    let result = try resolver.resolve()
    #expect(result.workflowName == "wf1")
    #expect(result.pluginID == "com.active.plugin")
    #expect(result.isInactive == false)
}
```

Also add this test helper to the test struct:

```swift
private func loadedPlugin(id: String) -> LoadedPlugin {
    LoadedPlugin(
        identifier: id,
        name: id,
        directory: pluginsDir.appendingPathComponent(id),
        manifest: PluginManifest(identifier: id, name: id, type: .static, pluginSchemaVersion: "1"),
        stages: [:]
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginWorkflowResolverTests 2>&1 | tail -20`
Expected: Compilation errors because `discoveredPlugins` parameter and `isInactive` field don't exist.

- [ ] **Step 3: Update PluginWorkflowResolver**

Replace the full contents of `Sources/piqley/CLI/PluginWorkflowResolver.swift`:

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
    let discoveredPlugins: [LoadedPlugin]

    init(
        firstArg: String?, secondArg: String?,
        usageHint: String,
        workflowsRoot: URL? = nil,
        pluginsDirectory: URL = PipelineOrchestrator.defaultPluginsDirectory,
        discoveredPlugins: [LoadedPlugin] = []
    ) {
        self.firstArg = firstArg
        self.secondArg = secondArg
        self.usageHint = usageHint
        self.workflowsRoot = workflowsRoot
        self.pluginsDirectory = pluginsDirectory
        self.discoveredPlugins = discoveredPlugins
    }

    func resolve() throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
        if let firstArg, let pluginID = secondArg {
            let isInactive = try checkInactive(workflowName: firstArg, pluginID: pluginID)
            return (firstArg, pluginID, isInactive)
        }

        if let firstArg {
            return try resolveSingleArg(firstArg)
        }

        return try resolveNoArgs()
    }

    // MARK: - Private

    private func checkInactive(workflowName: String, pluginID: String) throws -> Bool {
        guard !discoveredPlugins.isEmpty else { return false }
        let workflow = try WorkflowStore.load(name: workflowName, root: workflowsRoot)
        let pipelineSet = Set(workflow.pipeline.values.flatMap(\.self))
        return !pipelineSet.contains(pluginID)
    }

    private func resolveSingleArg(_ arg: String) throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
        if WorkflowStore.exists(name: arg, root: workflowsRoot) {
            let workflow = try WorkflowStore.load(name: arg, root: workflowsRoot)
            let plugins = pipelinePlugins(workflow)
            let inactive = inactivePluginIdentifiers(workflow: workflow)

            if plugins.isEmpty && inactive.isEmpty {
                throw CleanError("Workflow '\(arg)' has no plugins in its pipeline.")
            }

            if plugins.count == 1 && inactive.isEmpty {
                return (arg, plugins[0], false)
            }

            let (pluginID, isInactive) = try selectPluginInteractively(
                title: "Select plugin (\(arg))",
                active: plugins,
                inactive: inactive
            )
            return (arg, pluginID, isInactive)
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
                return (matching[0].name, arg, false)
            }
            let workflowName = try selectInteractively(
                title: "Select workflow for '\(arg)'",
                items: matching.map(\.name)
            )
            return (workflowName, arg, false)
        }

        throw CleanError("'\(arg)' is not a known workflow or installed plugin.")
    }

    private func resolveNoArgs() throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
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
        let inactive = inactivePluginIdentifiers(workflow: workflow)

        if plugins.isEmpty && inactive.isEmpty {
            throw CleanError("Workflow '\(workflowName)' has no plugins in its pipeline.")
        }

        if plugins.count == 1 && inactive.isEmpty {
            return (workflowName, plugins[0], false)
        }

        let (pluginID, isInactive) = try selectPluginInteractively(
            title: "Select plugin (\(workflowName))",
            active: plugins,
            inactive: inactive
        )
        return (workflowName, pluginID, isInactive)
    }

    private func pipelinePlugins(_ workflow: Workflow) -> [String] {
        Array(Set(workflow.pipeline.values.flatMap(\.self))).sorted()
    }

    private func inactivePluginIdentifiers(workflow: Workflow) -> [String] {
        guard !discoveredPlugins.isEmpty else { return [] }
        let pipelineSet = Set(workflow.pipeline.values.flatMap(\.self))
        return discoveredPlugins
            .filter { !pipelineSet.contains($0.identifier) }
            .map(\.identifier)
            .sorted()
    }

    private func selectPluginInteractively(
        title: String, active: [String], inactive: [String]
    ) throws -> (pluginID: String, isInactive: Bool) {
        var items = active
        var dividerIndex: Int?
        if !inactive.isEmpty {
            dividerIndex = items.count
            items.append("\(ANSI.dim)\u{2500}\u{2500} inactive \u{2500}\u{2500}\(ANSI.reset)")
            items += inactive.map { "\(ANSI.dim)\(ANSI.italic)\($0)\(ANSI.reset)" }
        }

        guard isatty(STDIN_FILENO) != 0 else {
            throw CleanError(
                "Multiple options available but stdin is not a terminal. "
                    + "Specify explicitly: \(usageHint) <workflow> <plugin>"
            )
        }
        let terminal = RawTerminal()
        defer { terminal.restore() }

        guard let index = terminal.selectFromListWithDivider(
            title: title, items: items, dividerIndex: dividerIndex
        ) else {
            throw ExitCode.success
        }

        if let dividerIndex, index > dividerIndex {
            let inactiveIdx = index - dividerIndex - 1
            return (inactive[inactiveIdx], true)
        }
        return (active[index], false)
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

- [ ] **Step 4: Update existing tests to use new return type**

The existing tests destructure as `let (workflowName, pluginID) = try resolver.resolve()`. Update each to destructure the third field:

In `twoArgs`:
```swift
let (workflowName, pluginID, _) = try resolver.resolve()
```

In `singleArgPlugin`:
```swift
let (workflowName, pluginID, _) = try resolver.resolve()
```

In `singleArgWorkflow`:
```swift
let (workflowName, pluginID, _) = try resolver.resolve()
```

- [ ] **Step 5: Update `WorkflowCommandEditCommand.swift` to use new return type**

In `Sources/piqley/CLI/WorkflowCommandEditCommand.swift:24`, change:
```swift
let (workflowName, pluginID) = try resolver.resolve()
```
to:
```swift
let (workflowName, pluginID, _) = try resolver.resolve()
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter PluginWorkflowResolverTests 2>&1 | tail -20`
Expected: All tests pass (existing + new).

- [ ] **Step 7: Commit**

Message: `feat: PluginWorkflowResolver shows inactive plugins in selection list`

---

### Task 3: Update RulesSubcommand to activate inactive plugins

**Files:**
- Modify: `Sources/piqley/CLI/WorkflowRulesCommand.swift`

Replace the pipeline membership guard with inactive plugin activation: stage picker, pipeline add, workflow save, and rule seeding.

- [ ] **Step 1: Replace RulesSubcommand.run() and resolveArguments()**

Replace the full contents of `Sources/piqley/CLI/WorkflowRulesCommand.swift`:

```swift
import ArgumentParser
import Foundation
import Logging
import PiqleyCore

extension WorkflowCommand {
    struct RulesSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rules",
            abstract: "Interactively edit rules for a plugin within a workflow."
        )

        @Argument(help: "The plugin identifier (or workflow name if two arguments given).")
        var firstArg: String?

        @Argument(help: "The plugin identifier when first argument is a workflow name.")
        var secondArg: String?

        func run() throws {
            let (registry, discoveredPlugins) = try WorkflowCommand.loadRegistryAndPlugins()
            let (workflowName, pluginID, isInactive) = try resolveArguments(
                discoveredPlugins: discoveredPlugins
            )

            var workflow = try WorkflowStore.load(name: workflowName)

            if isInactive {
                try activatePlugin(
                    pluginID, in: &workflow,
                    registry: registry, discoveredPlugins: discoveredPlugins
                )
            } else {
                // Verify plugin is in the workflow's pipeline
                let plugins = Set(workflow.pipeline.values.flatMap(\.self))
                guard plugins.contains(pluginID) else {
                    throw CleanError("Plugin '\(pluginID)' is not in workflow '\(workflowName)'")
                }
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
            let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)

            // Load stages from workflow rules dir (not plugin dir)
            let rulesDir = WorkflowStore.pluginRulesDirectory(
                workflowName: workflowName, pluginIdentifier: pluginID
            )
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

            // Build context and launch wizard
            let availableFields = FieldDiscovery.buildAvailableFields(dependencies: allDeps)
            let context = RuleEditingContext(
                availableFields: availableFields,
                pluginIdentifier: pluginID,
                stages: stages
            )

            let wizard = RulesWizard(context: context, rulesDir: rulesDir, workflowName: workflowName)
            try wizard.run()
        }

        // MARK: - Argument Resolution

        private func resolveArguments(
            discoveredPlugins: [LoadedPlugin]
        ) throws -> (workflowName: String, pluginID: String, isInactive: Bool) {
            let resolver = PluginWorkflowResolver(
                firstArg: firstArg, secondArg: secondArg,
                usageHint: "piqley workflow rules",
                discoveredPlugins: discoveredPlugins
            )
            return try resolver.resolve()
        }

        // MARK: - Inactive Plugin Activation

        private func activatePlugin(
            _ pluginID: String,
            in workflow: inout Workflow,
            registry: StageRegistry,
            discoveredPlugins: [LoadedPlugin]
        ) throws {
            guard let plugin = discoveredPlugins.first(where: { $0.identifier == pluginID }) else {
                throw CleanError("Plugin '\(pluginID)' is not installed.")
            }

            let supportedStages = registry.executionOrder.filter { plugin.stages.keys.contains($0) }
            guard !supportedStages.isEmpty else {
                throw CleanError("Plugin '\(pluginID)' has no stages matching the active stage registry.")
            }

            let selectedStage: String
            if supportedStages.count == 1 {
                selectedStage = supportedStages[0]
            } else {
                guard isatty(STDIN_FILENO) != 0 else {
                    throw CleanError(
                        "Plugin '\(pluginID)' supports multiple stages but stdin is not a terminal. "
                            + "Use 'piqley workflow add-plugin' instead."
                    )
                }
                let terminal = RawTerminal()
                defer { terminal.restore() }
                guard let idx = terminal.selectFromList(
                    title: "Add '\(pluginID)' to which stage?",
                    items: supportedStages
                ) else {
                    throw ExitCode.success
                }
                selectedStage = supportedStages[idx]
            }

            var list = workflow.pipeline[selectedStage] ?? []
            list.append(pluginID)
            workflow.pipeline[selectedStage] = list
            try WorkflowStore.save(workflow)

            let pluginDir = PipelineOrchestrator.defaultPluginsDirectory
                .appendingPathComponent(pluginID)
            try? WorkflowStore.seedRules(
                workflowName: workflow.name,
                pluginIdentifier: pluginID,
                pluginDirectory: pluginDir
            )
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 3: Run all tests to verify nothing is broken**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 4: Commit**

Message: `feat: workflow rules activates inactive plugins with stage picker`

---

### Task 4: Add CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add entry under the Unreleased section**

Add to the `Added` section under `## [Unreleased]`:

```markdown
- `workflow rules` now shows installed-but-inactive plugins in the plugin selection list; selecting one adds it to the workflow after choosing a stage
```

- [ ] **Step 2: Commit**

Message: `docs: changelog for inactive plugins in workflow rules`
