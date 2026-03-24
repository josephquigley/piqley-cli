# Expose All Namespaces in TUI Rules Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow the TUI rules editor to show fields from all installed plugins (not just declared dependencies), with save-time warnings when rules reference non-dependency namespaces.

**Architecture:** Expand `PluginRulesCommand` to scan all installed plugin manifests for field discovery. Add a namespace extraction helper and save-time validation to `RulesWizard`. Use `ReservedName.original` from PiqleyCore and a local `"read"` constant for built-in namespace filtering (adding `ReservedName.read` to PiqleyCore is deferred to a future PiqleyCore release).

**Tech Stack:** Swift, Swift Testing framework, PiqleyCore, ArgumentParser

**Spec:** `docs/superpowers/specs/2026-03-23-expose-all-namespaces-in-rules-editor-design.md`

---

### Task 1: Add namespace extraction helper and save validation to RulesWizard

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard.swift:6-20`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard+UI.swift:44-53`
- Test: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/NamespaceExtractionTests.swift`

- [ ] **Step 1: Write failing tests for namespace extraction**

Create `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/NamespaceExtractionTests.swift`:

```swift
import Testing
import PiqleyCore
@testable import piqley

@Suite("NamespaceExtraction")
struct NamespaceExtractionTests {

    // MARK: - extractReferencedNamespaces

    @Test("extracts namespace from match field")
    func extractsFromMatchField() {
        let rule = Rule(
            match: MatchConfig(field: "original:EXIF:ISO", pattern: "100"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["low-iso"], replacements: nil, source: nil)]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.contains("original"))
    }

    @Test("extracts namespace from emit clone source")
    func extractsFromEmitCloneSource() {
        let rule = Rule(
            match: MatchConfig(field: "original:EXIF:ISO", pattern: "100"),
            emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "com.example.tagger:tags")]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.contains("com.example.tagger"))
    }

    @Test("extracts namespace from write clone source")
    func extractsFromWriteCloneSource() {
        let rule = Rule(
            match: MatchConfig(field: "read:IPTC:Keywords", pattern: "landscape"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["nature"], replacements: nil, source: nil)],
            write: [EmitConfig(action: "clone", field: "IPTC:Keywords", values: nil, replacements: nil, source: "plugin.a:outputField")]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.contains("plugin.a"))
    }

    @Test("collects namespaces across multiple stages and slots")
    func collectsAcrossStagesAndSlots() {
        let rule1 = Rule(
            match: MatchConfig(field: "plugin.a:field1", pattern: "x"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["a"], replacements: nil, source: nil)]
        )
        let rule2 = Rule(
            match: MatchConfig(field: "plugin.b:field2", pattern: "y"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["b"], replacements: nil, source: nil)]
        )
        let stages: [String: StageConfig] = [
            "pre-process": StageConfig(preRules: [rule1], binary: nil, postRules: nil),
            "post-process": StageConfig(preRules: nil, binary: nil, postRules: [rule2]),
        ]
        let result = RulesWizard.extractReferencedNamespaces(from: stages)
        #expect(result.contains("plugin.a"))
        #expect(result.contains("plugin.b"))
    }

    @Test("returns empty set when no rules exist")
    func emptyWhenNoRules() {
        let stages: [String: StageConfig] = [
            "pre-process": StageConfig(preRules: nil, binary: nil, postRules: nil),
        ]
        let result = RulesWizard.extractReferencedNamespaces(from: stages)
        #expect(result.isEmpty)
    }

    // MARK: - nonDependencyNamespaces

    @Test("filters out built-in namespaces and dependencies")
    func filtersBuiltInsAndDependencies() {
        let allNamespaces: Set<String> = ["original", "read", "plugin.a", "plugin.b"]
        let dependencies: Set<String> = ["plugin.a"]
        let result = RulesWizard.nonDependencyNamespaces(allNamespaces, dependencies: dependencies)
        #expect(result == ["plugin.b"])
    }

    @Test("returns empty when all namespaces are built-in or dependencies")
    func emptyWhenAllAccountedFor() {
        let allNamespaces: Set<String> = ["original", "read", "plugin.a"]
        let dependencies: Set<String> = ["plugin.a"]
        let result = RulesWizard.nonDependencyNamespaces(allNamespaces, dependencies: dependencies)
        #expect(result.isEmpty)
    }

    @Test("returns all plugin namespaces when no dependencies declared")
    func allPluginNamespacesWhenNoDeps() {
        let allNamespaces: Set<String> = ["original", "read", "plugin.a", "plugin.b"]
        let dependencies: Set<String> = []
        let result = RulesWizard.nonDependencyNamespaces(allNamespaces, dependencies: dependencies)
        #expect(result == ["plugin.a", "plugin.b"])
    }

    @Test("match field without colon produces no namespace")
    func matchFieldWithoutColon() {
        let rule = Rule(
            match: MatchConfig(field: "keywords", pattern: "test"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["x"], replacements: nil, source: nil)]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter NamespaceExtraction 2>&1 | tail -10`
Expected: Compilation error (methods don't exist yet). 9 tests total.

- [ ] **Step 3: Add `dependencyIdentifiers` property to RulesWizard**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard.swift`, add property and update init:

Replace lines 6-20:
```swift
/// ANSI-based interactive rule editor wizard.
/// Uses raw terminal mode with cursor-positioned selection lists.
final class RulesWizard {
    var context: RuleEditingContext
    let pluginDir: URL
    let terminal: RawTerminal
    let dependencyIdentifiers: Set<String>
    var modified = false
    var savedAt: Date?

    /// Tracks which rules are marked for deletion (by stage + slot + index).
    /// Deleted rules are shown struck-through and removed on save.
    var deletedRules: Set<String> = []

    init(context: RuleEditingContext, pluginDir: URL, dependencyIdentifiers: Set<String> = []) {
        self.context = context
        self.pluginDir = pluginDir
        self.dependencyIdentifiers = dependencyIdentifiers
        terminal = RawTerminal()
```

- [ ] **Step 4: Add static extraction and filtering methods to RulesWizard**

Add after the `readKeyWithSaveTimeout()` method (around line 50), before the `// MARK: - Stage Select` section:

```swift
    // MARK: - Namespace Validation

    /// Extracts all namespace prefixes referenced by rules across all stages.
    /// Splits match fields and clone source references on the first `:`.
    static func extractReferencedNamespaces(from stages: [String: StageConfig]) -> Set<String> {
        var namespaces = Set<String>()

        func extractNamespace(from qualifiedField: String) -> String? {
            guard let colonIndex = qualifiedField.firstIndex(of: ":") else { return nil }
            let ns = String(qualifiedField[qualifiedField.startIndex..<colonIndex])
            return ns.isEmpty ? nil : ns
        }

        func processEmitConfigs(_ configs: [EmitConfig]) {
            for config in configs {
                if let source = config.source,
                   let ns = extractNamespace(from: source) {
                    namespaces.insert(ns)
                }
            }
        }

        for (_, stage) in stages {
            let allRules = (stage.preRules ?? []) + (stage.postRules ?? [])
            for rule in allRules {
                if let ns = extractNamespace(from: rule.match.field) {
                    namespaces.insert(ns)
                }
                processEmitConfigs(rule.emit)
                processEmitConfigs(rule.write)
            }
        }

        return namespaces
    }

    /// Returns the set of plugin namespaces that are NOT declared dependencies
    /// (filtering out built-in namespaces).
    static func nonDependencyNamespaces(
        _ referenced: Set<String>,
        dependencies: Set<String>
    ) -> Set<String> {
        // TODO: Replace "read" with ReservedName.read once PiqleyCore publishes that constant
        let builtIn: Set<String> = [ReservedName.original, "read"]
        return referenced.subtracting(builtIn).subtracting(dependencies)
    }
```

These two static methods are added directly into the `RulesWizard` class body, between `readKeyWithSaveTimeout()` and the `// MARK: - Stage Select` section.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter NamespaceExtraction 2>&1 | tail -10`
Expected: All 9 tests pass

- [ ] **Step 6: Update `save()` with validation**

In `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard+UI.swift`, replace the `save()` method (lines 44-53):

```swift
    /// Save current state to disk without exiting.
    func save() {
        applyDeletions()

        // Check for non-dependency namespace references
        let referenced = Self.extractReferencedNamespaces(from: context.stages)
        let nonDeps = Self.nonDependencyNamespaces(referenced, dependencies: dependencyIdentifiers)
        if !nonDeps.isEmpty {
            let names = nonDeps.sorted().joined(separator: ", ")
            if !terminal.confirm(
                "Rules reference plugins that are not declared dependencies: \(names). Save anyway?"
            ) {
                return
            }
        }

        do {
            try StageFileManager.saveStages(context.stages, to: pluginDir)
            modified = false
            savedAt = Date()
        } catch {
            terminal.showMessage("Error saving: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 7: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 8: Commit**

Commit message: `feat: add namespace extraction and save-time validation for non-dependency references`

---

### Task 2: Scan all installed plugins in PluginRulesCommand

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/PluginRulesCommand.swift:45-68`

- [ ] **Step 1: Replace dependency-only scan with all-plugins scan**

Replace lines 45-68 of `PluginRulesCommand.swift` (from `// 4. Build dependency info` to the end of `run()`) with:

```swift
        // 4. Build field info from all installed plugins
        // This includes the plugin being edited (it may reference its own fields from earlier stages).
        // Directories with missing/malformed manifests are silently skipped via try?.
        var deps: [FieldDiscovery.DependencyInfo] = []
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
        if let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in pluginDirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let manifestURL = dir.appendingPathComponent(PluginFile.manifest)
                if let data = try? Data(contentsOf: manifestURL),
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

        // 5. Build context
        let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
        let context = RuleEditingContext(
            availableFields: availableFields,
            pluginIdentifier: pluginID,
            stages: stages
        )

        // 6. Launch wizard
        let dependencyIDs = Set(manifest.dependencyIdentifiers)
        let wizard = RulesWizard(context: context, pluginDir: pluginDir, dependencyIdentifiers: dependencyIDs)
        try wizard.run()
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

Commit message: `feat: scan all installed plugins for rule editor field discovery`

---

### Task 3: Update field selection label

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Wizard/RulesWizard+FieldSelection.swift:13`

- [ ] **Step 1: Change label from "dependency plugin" to "plugin"**

In `RulesWizard+FieldSelection.swift`, replace line 13:

```swift
            default: return "\(source)  \(ANSI.dim)\u{2014} plugin\(ANSI.reset)"
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

Commit message: `refactor: update field selection label from "dependency plugin" to "plugin"`

---

### Task 4: Run full test suite

- [ ] **Step 1: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 2: Final commit if any fixes needed**

If tests revealed issues, fix and commit with message describing the fix.
