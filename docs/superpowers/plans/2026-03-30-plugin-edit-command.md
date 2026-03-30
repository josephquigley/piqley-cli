# Plugin Edit Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `piqley plugin edit [plugin-identifier]` to edit the default rules of mutable plugins via the existing RulesWizard TUI.

**Architecture:** Thin CLI wrapper (`EditSubcommand`) in PluginCommand.swift that loads a mutable plugin, builds a `RuleEditingContext` from the plugin's own fields + dependency fields, then launches `RulesWizard`. Requires making `RulesWizard.workflowName` optional to skip the workflow-specific post-save prompt.

**Tech Stack:** Swift, ArgumentParser, PiqleyCore, RawTerminal TUI

---

## File Structure

- **Modify:** `Sources/piqley/CLI/PluginCommand.swift` - Add `EditSubcommand`
- **Modify:** `Sources/piqley/Wizard/RulesWizard.swift` - Make `workflowName` optional
- **Modify:** `Sources/piqley/Wizard/RulesWizard+UI.swift` - Guard `promptToAddToMissingStages` on non-nil `workflowName`

---

### Task 1: Make RulesWizard.workflowName Optional

The `save()` method calls `promptToAddToMissingStages()` which loads a workflow by name. When editing plugin defaults directly, there is no workflow. Make `workflowName` optional and skip the prompt when nil.

**Files:**
- Modify: `Sources/piqley/Wizard/RulesWizard.swift:9,18`
- Modify: `Sources/piqley/Wizard/RulesWizard+UI.swift:51,59-60`

- [ ] **Step 1: Change workflowName type to String?**

In `Sources/piqley/Wizard/RulesWizard.swift`, change the property and init:

```swift
// Line 9: change type
let workflowName: String?

// Line 18: change init parameter
init(context: RuleEditingContext, rulesDir: URL, workflowName: String? = nil) {
```

- [ ] **Step 2: Guard promptToAddToMissingStages on non-nil workflowName**

In `Sources/piqley/Wizard/RulesWizard+UI.swift`, update the `save()` method to skip the prompt when there's no workflow context:

```swift
// Line 51: wrap in guard
func save() {
    applyDeletions()

    do {
        try StageFileManager.saveStages(context.stages, to: rulesDir)
        modified = false
        savedAt = Date()
        if workflowName != nil {
            promptToAddToMissingStages()
        }
    } catch {
        terminal.showMessage("Error saving: \(error.localizedDescription)")
    }
}
```

Also update `promptToAddToMissingStages` to unwrap:

```swift
// Line 59-60: guard let
private func promptToAddToMissingStages() {
    guard let workflowName, var workflow = try? WorkflowStore.load(name: workflowName) else { return }
```

- [ ] **Step 3: Verify existing call sites still compile**

The only call site passing `workflowName` is in `WorkflowRulesCommand.swift` line 91:
```swift
let wizard = RulesWizard(context: context, rulesDir: rulesDir, workflowName: workflowName)
```
This already passes a `String`, which is compatible with `String?`. No changes needed.

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

Message: `refactor: make RulesWizard.workflowName optional to support non-workflow contexts`

---

### Task 2: Add EditSubcommand to PluginCommand

**Files:**
- Modify: `Sources/piqley/CLI/PluginCommand.swift:11-15` (add to subcommands array)
- Modify: `Sources/piqley/CLI/PluginCommand.swift` (add struct at end of file, before closing brace)

- [ ] **Step 1: Register EditSubcommand in subcommands array**

In `Sources/piqley/CLI/PluginCommand.swift`, add `EditSubcommand.self` to the subcommands array at line 12:

```swift
subcommands: [
    ListSubcommand.self, SetupSubcommand.self, InitSubcommand.self,
    CreateSubcommand.self, InstallSubcommand.self, UpdateSubcommand.self,
    UninstallSubcommand.self, EditSubcommand.self,
]
```

- [ ] **Step 2: Add EditSubcommand struct**

Add this extension at the end of PluginCommand.swift, before the final closing `}`:

```swift
struct EditSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit rules for a mutable plugin"
    )

    @Argument(help: "Plugin identifier (shows picker if omitted)")
    var pluginIdentifier: String?

    func run() throws {
        let (registry, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()

        let mutablePlugins = allPlugins.filter { $0.manifest.type == .mutable }
        let staticCount = allPlugins.count - mutablePlugins.count

        let selected: LoadedPlugin
        if let pluginIdentifier {
            // Direct identifier provided
            guard let plugin = allPlugins.first(where: { $0.identifier == pluginIdentifier }) else {
                throw CleanError("No plugin found with identifier '\(pluginIdentifier)'.")
            }
            guard plugin.manifest.type == .mutable else {
                throw CleanError(
                    "'\(plugin.name)' is a static plugin and cannot be modified. "
                        + "Config values can be changed with 'piqley plugin setup'."
                )
            }
            selected = plugin
        } else {
            // Interactive picker
            guard !mutablePlugins.isEmpty else {
                throw CleanError("No editable plugins installed. Create one with 'piqley plugin init'.")
            }
            guard isatty(STDIN_FILENO) != 0 else {
                throw CleanError("No plugin specified and stdin is not a terminal.")
            }

            let terminal = RawTerminal()
            let items = mutablePlugins.map { "\($0.identifier)  \(ANSI.dim)\($0.name)\(ANSI.reset)" }
            let footer = staticCount > 0
                ? "(\(staticCount) unmodifiable plugin\(staticCount == 1 ? "" : "s") not shown. Use the workflow rules editor to adjust their default behavior.)"
                : nil
            guard let idx = terminal.selectFromFilterableList(
                title: "Select a plugin to edit\(footer.map { "\n\(ANSI.dim)\($0)\(ANSI.reset)" } ?? "")",
                items: items
            ) else {
                terminal.restore()
                return
            }
            terminal.restore()
            selected = mutablePlugins[idx]
        }

        // Load manifest for fields and dependencies
        let manifest = selected.manifest
        let pluginDir = selected.directory
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

        // Build field dependencies from manifest dependencies
        var deps: [FieldDiscovery.DependencyInfo] = []
        for depId in manifest.dependencyIdentifiers {
            let depManifestURL = pluginsDir
                .appendingPathComponent(depId)
                .appendingPathComponent(PluginFile.manifest)
            guard let depData = try? Data(contentsOf: depManifestURL),
                  let depManifest = try? JSONDecoder.piqley.decode(PluginManifest.self, from: depData)
            else { continue }
            if !depManifest.fields.isEmpty {
                deps.append(FieldDiscovery.DependencyInfo(identifier: depId, fields: depManifest.fields))
            }
        }

        // Add the plugin's own fields
        if !manifest.fields.isEmpty {
            deps.append(FieldDiscovery.DependencyInfo(
                identifier: selected.identifier,
                fields: manifest.fields
            ))
        }

        // Load stages from plugin directory
        let knownHooks = registry.allKnownNames
        var (stages, _) = PluginDiscovery.loadStages(
            from: pluginDir,
            knownHooks: knownHooks,
            logger: Logger(label: "piqley.plugin.edit")
        )

        // Ensure all known stages are present (in-memory only)
        for stageName in registry.executionOrder where stages[stageName] == nil {
            stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
        }

        // Build context and launch wizard
        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: selected.identifier,
            stages: stages
        )

        let wizard = RulesWizard(context: context, rulesDir: pluginDir)
        try wizard.run()
    }
}
```

- [ ] **Step 3: Verify import for Logger**

`PluginCommand.swift` already imports `Logging` at line 3. No additional imports needed.

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Manual smoke test**

Run: `swift run piqley plugin edit`
Expected: Shows filterable list of mutable plugins (camera-tagger, negativelabpro.sanitizer) with the "(3 unmodifiable plugins not shown...)" message.

Run: `swift run piqley plugin edit photo.quigs.camera-tagger`
Expected: Opens stage selector TUI showing pre-process, post-process, publish, post-publish stages with rule counts.

Run: `swift run piqley plugin edit photo.quigs.resize`
Expected: Error message about static plugin.

- [ ] **Step 6: Commit**

Message: `feat: add 'piqley plugin edit' command for editing mutable plugin rules`
