# Upstream Field Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover plugin namespaces and their emitted fields by scanning upstream plugins' rules JSON files in the same workflow, replacing the current broken manifest-scanning approach.

**Architecture:** Add a `discoverUpstreamFields` method to `FieldDiscovery` that computes upstream plugins from the workflow pipeline + stage ordering, scans their rules files for emit field names, and returns `[DependencyInfo]`. Replace the scan block in `PluginRulesCommand`.

**Tech Stack:** Swift 6.0, Swift Testing framework, PiqleyCore

**Spec:** `docs/superpowers/specs/2026-03-24-upstream-field-discovery-design.md`

---

### Task 1: Add failing tests for upstream field discovery

**Files:**
- Modify: `Tests/piqleyTests/FieldDiscoveryTests.swift`

- [ ] **Step 1: Write tests for `discoverUpstreamFields`**

These tests operate on a temporary directory with rules JSON files. Add a new `// MARK: - Upstream field discovery` section at the end of the test file.

Helper to create a stage rules JSON file with emit fields:

```swift
// MARK: - Upstream field discovery

private func createRulesFile(
    at baseDir: URL,
    pluginId: String,
    stageName: String,
    emitFields: [String]
) throws {
    let pluginDir = baseDir.appendingPathComponent(pluginId)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    let rules: [[String: Any]] = emitFields.map { field in
        [
            "match": ["field": "original:IPTC:Keywords", "pattern": "glob:*"],
            "emit": [["field": field, "values": ["test"]]],
            "write": []
        ]
    }
    let stageConfig: [String: Any] = ["preRules": rules]
    let data = try JSONSerialization.data(withJSONObject: stageConfig)
    let file = pluginDir.appendingPathComponent("stage-\(stageName).json")
    try data.write(to: file)
}
```

Tests:

```swift
@Test("discovers emit fields from upstream plugin rules")
func discoversUpstreamEmitFields() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try createRulesFile(
        at: tmpDir, pluginId: "plugin.upstream",
        stageName: "pre-process", emitFields: ["IPTC:Keywords", "score"]
    )

    let pipeline: [String: [String]] = [
        "pre-process": ["plugin.upstream"],
        "publish": ["plugin.target"]
    ]
    let stageOrder = ["pre-process", "publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.target",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    let upstream = deps.first { $0.identifier == "plugin.upstream" }
    #expect(upstream != nil)
    #expect(Set(upstream?.fields ?? []) == Set(["IPTC:Keywords", "score"]))
}

@Test("includes self-emitted fields")
func includesSelfEmittedFields() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try createRulesFile(
        at: tmpDir, pluginId: "plugin.target",
        stageName: "publish", emitFields: ["tags"]
    )

    let pipeline: [String: [String]] = [
        "publish": ["plugin.target"]
    ]
    let stageOrder = ["publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.target",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    let selfDep = deps.first { $0.identifier == "plugin.target" }
    #expect(selfDep != nil)
    #expect(selfDep?.fields == ["tags"])
}

@Test("same-stage plugin earlier in array is upstream")
func sameStageEarlierPluginIsUpstream() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try createRulesFile(
        at: tmpDir, pluginId: "plugin.first",
        stageName: "publish", emitFields: ["title"]
    )

    let pipeline: [String: [String]] = [
        "publish": ["plugin.first", "plugin.second"]
    ]
    let stageOrder = ["publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.second",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    let first = deps.first { $0.identifier == "plugin.first" }
    #expect(first != nil)
    #expect(first?.fields == ["title"])
}

@Test("only harvests from upstream stages, not later stages")
func onlyHarvestsUpstreamStages() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Plugin appears in both pre-process and post-publish
    try createRulesFile(
        at: tmpDir, pluginId: "plugin.multi",
        stageName: "pre-process", emitFields: ["upstream-field"]
    )
    try createRulesFile(
        at: tmpDir, pluginId: "plugin.multi",
        stageName: "post-publish", emitFields: ["downstream-field"]
    )

    let pipeline: [String: [String]] = [
        "pre-process": ["plugin.multi"],
        "publish": ["plugin.target"],
        "post-publish": ["plugin.multi"]
    ]
    let stageOrder = ["pre-process", "publish", "post-publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.target",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    let multi = deps.first { $0.identifier == "plugin.multi" }
    #expect(multi != nil)
    #expect(multi?.fields == ["upstream-field"])
    // downstream-field should NOT appear
}

@Test("excludes nil and wildcard emit fields")
func excludesNilAndWildcardFields() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let pluginDir = tmpDir.appendingPathComponent("plugin.upstream")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    // Manually build JSON with skip (nil field) and clone wildcard
    let json: [String: Any] = [
        "preRules": [
            [
                "match": ["field": "original:IPTC:Keywords", "pattern": "glob:*"],
                "emit": [
                    ["field": "good-field", "values": ["test"]],
                    ["action": "skip"],
                    ["action": "clone", "field": "*", "source": "original"]
                ],
                "write": []
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))

    let pipeline: [String: [String]] = [
        "pre-process": ["plugin.upstream"],
        "publish": ["plugin.target"]
    ]
    let stageOrder = ["pre-process", "publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.target",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    let upstream = deps.first { $0.identifier == "plugin.upstream" }
    #expect(upstream?.fields == ["good-field"])
}

@Test("missing rules directory produces no dependency")
func missingRulesDirProducesNoDep() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let pipeline: [String: [String]] = [
        "pre-process": ["plugin.upstream"],
        "publish": ["plugin.target"]
    ]
    let stageOrder = ["pre-process", "publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.target",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    #expect(deps.isEmpty)
}

@Test("harvests from postRules as well as preRules")
func harvestsFromPostRules() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let pluginDir = tmpDir.appendingPathComponent("plugin.upstream")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    let json: [String: Any] = [
        "postRules": [
            [
                "match": ["field": "original:IPTC:Keywords", "pattern": "glob:*"],
                "emit": [["field": "post-field", "values": ["test"]]],
                "write": []
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))

    let pipeline: [String: [String]] = [
        "pre-process": ["plugin.upstream"],
        "publish": ["plugin.target"]
    ]
    let stageOrder = ["pre-process", "publish"]

    let deps = FieldDiscovery.discoverUpstreamFields(
        pipeline: pipeline,
        targetPlugin: "plugin.target",
        stageOrder: stageOrder,
        rulesBaseDir: tmpDir
    )

    let upstream = deps.first { $0.identifier == "plugin.upstream" }
    #expect(upstream?.fields == ["post-field"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FieldDiscoveryTests 2>&1 | tail -20`
Expected: compilation error because `discoverUpstreamFields` does not exist yet.

- [ ] **Step 3: Commit**

```
test: add failing tests for upstream field discovery
```

---

### Task 2: Implement `discoverUpstreamFields` on `FieldDiscovery`

**Files:**
- Modify: `Sources/piqley/Wizard/FieldDiscovery.swift`

- [ ] **Step 1: Add the `discoverUpstreamFields` method**

Add after the existing `buildAvailableFields` method:

```swift
// MARK: - Upstream Discovery

/// Discovers emitted fields from upstream plugins by scanning their rules JSON files.
///
/// "Upstream" means: all plugins in stages before the target's stage, plus plugins
/// earlier in the same stage's array. The target plugin itself is also included.
///
/// - Parameters:
///   - pipeline: The workflow pipeline dictionary (stage name -> ordered plugin IDs).
///   - targetPlugin: The plugin identifier being edited.
///   - stageOrder: The ordered list of active stage names.
///   - rulesBaseDir: The workflow's rules base directory.
/// - Returns: An array of `DependencyInfo` for each upstream plugin that has emitted fields.
static func discoverUpstreamFields(
    pipeline: [String: [String]],
    targetPlugin: String,
    stageOrder: [String],
    rulesBaseDir: URL
) -> [DependencyInfo] {
    // 1. Find target's stage and position
    var targetStageIndex = stageOrder.count
    var targetPosition = 0
    for (stageIdx, stage) in stageOrder.enumerated() {
        let plugins = pipeline[stage] ?? []
        if let pos = plugins.firstIndex(of: targetPlugin) {
            targetStageIndex = stageIdx
            targetPosition = pos
            break
        }
    }

    // 2. Collect upstream plugins and which stages they're upstream in
    // Key: pluginId, Value: set of stage names where they're upstream
    var upstreamStages: [(identifier: String, stages: Set<String>)] = []
    var seen: [String: Int] = [:] // pluginId -> index in upstreamStages

    for (stageIdx, stage) in stageOrder.enumerated() {
        guard stageIdx <= targetStageIndex else { break }
        let plugins = pipeline[stage] ?? []

        for (pluginIdx, pluginId) in plugins.enumerated() {
            // Skip plugins that aren't upstream
            if stageIdx == targetStageIndex && pluginId != targetPlugin && pluginIdx >= targetPosition {
                continue
            }
            if stageIdx == targetStageIndex && pluginId != targetPlugin && pluginIdx >= targetPosition {
                continue
            }

            if let existingIdx = seen[pluginId] {
                upstreamStages[existingIdx].stages.insert(stage)
            } else {
                seen[pluginId] = upstreamStages.count
                upstreamStages.append((identifier: pluginId, stages: [stage]))
            }
        }
    }

    // 3. Harvest fields from each upstream plugin's rules files
    var result: [DependencyInfo] = []
    for entry in upstreamStages {
        var fields: Set<String> = []
        for stage in entry.stages {
            let filename = "\(PluginFile.stagePrefix)\(stage)\(PluginFile.stageSuffix)"
            let fileURL = rulesBaseDir
                .appendingPathComponent(entry.identifier)
                .appendingPathComponent(filename)

            guard let data = try? Data(contentsOf: fileURL),
                  let stageConfig = try? JSONDecoder.piqley.decode(StageConfig.self, from: data)
            else { continue }

            let allRules = (stageConfig.preRules ?? []) + (stageConfig.postRules ?? [])
            for rule in allRules {
                for emit in rule.emit {
                    if let field = emit.field, field != "*" {
                        fields.insert(field)
                    }
                }
            }
        }

        if !fields.isEmpty {
            result.append(DependencyInfo(
                identifier: entry.identifier,
                fields: Array(fields)
            ))
        }
    }

    return result
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter FieldDiscoveryTests 2>&1 | tail -30`
Expected: all tests pass.

- [ ] **Step 3: Commit**

```
feat: discover upstream plugin fields from workflow rules files
```

---

### Task 3: Wire up `PluginRulesCommand` to use the new discovery

**Files:**
- Modify: `Sources/piqley/CLI/PluginRulesCommand.swift`

- [ ] **Step 1: Replace lines 61-82 with a call to `discoverUpstreamFields`**

Replace the entire block:

```swift
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
           let pluginManifest = try? JSONDecoder.piqley.decode(PluginManifest.self, from: data)
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
```

With:

```swift
// Discover fields from upstream plugins' rules files
let rulesBaseDir = WorkflowStore.rulesDirectory(name: workflowName)
let deps = FieldDiscovery.discoverUpstreamFields(
    pipeline: workflow.pipeline,
    targetPlugin: pluginID,
    stageOrder: registry.executionOrder,
    rulesBaseDir: rulesBaseDir
)
```

- [ ] **Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 3: Commit**

```
feat: use upstream field discovery in rules editor
```
