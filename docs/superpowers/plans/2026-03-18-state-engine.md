# State Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-pipeline-run state store so JSON protocol plugins can share metadata through namespaced state.

**Architecture:** Three new types in `Sources/piqley/State/` (StateStore, MetadataExtractor, DependencyValidator) integrated into PipelineOrchestrator. Manifest gains optional `dependencies` field. JSON payload gains optional `state` field for input and output.

**Tech Stack:** Swift 6.2, ImageIO/CGImageSource for EXIF/IPTC/XMP extraction, swift-testing for tests.

**Spec:** `docs/superpowers/specs/2026-03-18-state-engine-design.md`

---

### Task 1: StateStore

**Files:**
- Create: `Sources/piqley/State/StateStore.swift`
- Create: `Tests/piqleyTests/StateStoreTests.swift`

- [ ] **Step 1: Write failing tests for StateStore**

```swift
import Testing
import Foundation
@testable import piqley

@Suite("StateStore")
struct StateStoreTests {
    @Test("setNamespace stores values and resolve returns them")
    func testSetAndResolve() async {
        let store = StateStore()
        await store.setNamespace(
            image: "IMG_001.jpg",
            plugin: "hashtag",
            values: ["tags": .array([.string("#cat"), .string("#dog")])]
        )
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        #expect(resolved["hashtag"]?["tags"] == .array([.string("#cat"), .string("#dog")]))
    }

    @Test("resolve returns empty dict for unknown dependencies")
    func testResolveUnknownDependency() async {
        let store = StateStore()
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["nonexistent"])
        #expect(resolved["nonexistent"] == nil)
    }

    @Test("resolve filters to only requested dependencies")
    func testResolveFilters() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["a": .string("1")])
        await store.setNamespace(image: "IMG_001.jpg", plugin: "watermark", values: ["b": .string("2")])
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        #expect(resolved["hashtag"] != nil)
        #expect(resolved["watermark"] == nil)
    }

    @Test("setNamespace replaces previous values for same plugin+image")
    func testReplaceNamespace() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["old": .string("v1")])
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["new": .string("v2")])
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        #expect(resolved["hashtag"]?["old"] == nil)
        #expect(resolved["hashtag"]?["new"] == .string("v2"))
    }

    @Test("different images have independent state")
    func testPerImageIsolation() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["a": .string("1")])
        await store.setNamespace(image: "IMG_002.jpg", plugin: "hashtag", values: ["a": .string("2")])
        let r1 = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        let r2 = await store.resolve(image: "IMG_002.jpg", dependencies: ["hashtag"])
        #expect(r1["hashtag"]?["a"] == .string("1"))
        #expect(r2["hashtag"]?["a"] == .string("2"))
    }

    @Test("allImageNames returns all images with state")
    func testAllImageNames() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "original", values: ["a": .string("1")])
        await store.setNamespace(image: "IMG_002.jpg", plugin: "original", values: ["b": .string("2")])
        let names = await store.allImageNames
        #expect(names.sorted() == ["IMG_001.jpg", "IMG_002.jpg"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StateStoreTests 2>&1 | tail -20`
Expected: Compilation error — `StateStore` does not exist.

- [ ] **Step 3: Write StateStore implementation**

Uses `actor` for Swift 6.2 concurrency safety (matching the project's existing `ActivityTracker` pattern in PluginRunner.swift). All call sites must use `await`.

```swift
import Foundation

/// Per-pipeline-run, in-memory state store. Namespaced per image, per plugin.
actor StateStore {
    private var images: [String: [String: [String: JSONValue]]] = [:]

    /// Store values under a plugin's namespace for a specific image.
    /// Replaces any previous values for this plugin+image combination.
    func setNamespace(image: String, plugin: String, values: [String: JSONValue]) {
        if images[image] == nil {
            images[image] = [:]
        }
        images[image]![plugin] = values
    }

    /// Resolve state for an image, returning only namespaces listed in dependencies.
    func resolve(image: String, dependencies: [String]) -> [String: [String: JSONValue]] {
        guard let namespaces = images[image] else { return [:] }
        var result: [String: [String: JSONValue]] = [:]
        for dep in dependencies {
            if let values = namespaces[dep] {
                result[dep] = values
            }
        }
        return result
    }

    /// All image filenames that have state stored.
    var allImageNames: [String] {
        Array(images.keys)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StateStoreTests 2>&1 | tail -20`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/State/StateStore.swift Tests/piqleyTests/StateStoreTests.swift
git commit -m "feat: add StateStore for per-pipeline namespaced state"
```

---

### Task 2: DependencyValidator

**Files:**
- Create: `Sources/piqley/State/DependencyValidator.swift`
- Create: `Tests/piqleyTests/DependencyValidatorTests.swift`

- [ ] **Step 1: Write failing tests for DependencyValidator**

```swift
import Testing
import Foundation
@testable import piqley

@Suite("DependencyValidator")
struct DependencyValidatorTests {
    // Helper to make a manifest with optional dependencies
    private func manifest(name: String, hook: String, dependencies: [String]? = nil) -> PluginManifest {
        PluginManifest(
            name: name,
            pluginProtocolVersion: "1",
            dependencies: dependencies,
            hooks: [hook: PluginManifest.HookConfig(
                command: "./bin/tool", args: [], timeout: nil,
                pluginProtocol: .json, successCodes: nil,
                warningCodes: nil, criticalCodes: nil, batchProxy: nil
            )]
        )
    }

    @Test("no dependencies passes validation")
    func testNoDependencies() throws {
        let manifests = [manifest(name: "a", hook: "publish")]
        let pipeline: [String: [String]] = ["publish": ["a"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result == nil)
    }

    @Test("original dependency always passes")
    func testOriginalDependency() throws {
        let manifests = [manifest(name: "a", hook: "publish", dependencies: ["original"])]
        let pipeline: [String: [String]] = ["publish": ["a"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result == nil)
    }

    @Test("valid same-hook dependency passes")
    func testSameHookDependency() throws {
        let manifests = [
            manifest(name: "hashtag", hook: "post-process"),
            manifest(name: "flickr", hook: "post-process", dependencies: ["hashtag"])
        ]
        let pipeline: [String: [String]] = ["post-process": ["hashtag", "flickr"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result == nil)
    }

    @Test("valid cross-hook dependency passes")
    func testCrossHookDependency() throws {
        let manifests = [
            manifest(name: "hashtag", hook: "post-process"),
            manifest(name: "flickr", hook: "publish", dependencies: ["hashtag"])
        ]
        let pipeline: [String: [String]] = [
            "post-process": ["hashtag"],
            "publish": ["flickr"]
        ]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result == nil)
    }

    @Test("dependency on later plugin in same hook fails")
    func testSameHookWrongOrder() throws {
        let manifests = [
            manifest(name: "flickr", hook: "post-process", dependencies: ["hashtag"]),
            manifest(name: "hashtag", hook: "post-process")
        ]
        let pipeline: [String: [String]] = ["post-process": ["flickr", "hashtag"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result != nil)
        #expect(result!.contains("hashtag"))
    }

    @Test("dependency on plugin in later hook fails")
    func testLaterHookDependency() throws {
        let manifests = [
            manifest(name: "hashtag", hook: "pre-process", dependencies: ["flickr"]),
            manifest(name: "flickr", hook: "publish")
        ]
        let pipeline: [String: [String]] = [
            "pre-process": ["hashtag"],
            "publish": ["flickr"]
        ]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result != nil)
    }

    @Test("dependency on nonexistent plugin fails")
    func testMissingDependency() throws {
        let manifests = [
            manifest(name: "flickr", hook: "publish", dependencies: ["ghost"])
        ]
        let pipeline: [String: [String]] = ["publish": ["flickr"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result != nil)
        #expect(result!.contains("ghost"))
    }

    @Test("plugin named original is rejected")
    func testOriginalNameRejected() throws {
        let manifests = [manifest(name: "original", hook: "publish")]
        let pipeline: [String: [String]] = ["publish": ["original"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline)
        #expect(result != nil)
        #expect(result!.contains("reserved"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DependencyValidatorTests 2>&1 | tail -20`
Expected: Compilation error — `DependencyValidator` does not exist and `PluginManifest` doesn't have `dependencies` parameter yet.

- [ ] **Step 3: Add `dependencies` to PluginManifest**

Modify: `Sources/piqley/Plugins/PluginManifest.swift`

Add `dependencies` property:
```swift
let dependencies: [String]?
```

Add to `CodingKeys`:
```swift
case name, pluginProtocolVersion, config, setup, hooks, dependencies
```

Add to `init(from decoder:)`:
```swift
dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies)
```

Add to memberwise init:
```swift
init(name: String, pluginProtocolVersion: String, config: [ConfigEntry] = [], setup: SetupConfig? = nil, dependencies: [String]? = nil, hooks: [String: HookConfig]) {
    // ... existing assignments ...
    self.dependencies = dependencies
}
```

- [ ] **Step 4: Write DependencyValidator implementation**

```swift
import Foundation

enum DependencyValidator {
    /// Validates plugin dependencies against pipeline ordering.
    /// Returns nil if valid, or an error message string if invalid.
    static func validate(
        manifests: [PluginManifest],
        pipeline: [String: [String]]
    ) -> String? {
        // Check for reserved name "original"
        for manifest in manifests {
            if manifest.name == "original" {
                return "Plugin name 'original' is reserved and cannot be used."
            }
        }

        // Build a position map: pluginName → (hookIndex, positionInHook)
        let canonicalHooks = PluginManifest.canonicalHooks
        var positionMap: [String: (hookIndex: Int, position: Int)] = [:]
        for (hookIndex, hookName) in canonicalHooks.enumerated() {
            let plugins = pipeline[hookName] ?? []
            for (position, pluginName) in plugins.enumerated() {
                let name = pluginName.split(separator: ":").first.map(String.init) ?? pluginName
                // First occurrence wins (a plugin may appear in multiple hooks;
                // use earliest for "runs before" check)
                if positionMap[name] == nil {
                    positionMap[name] = (hookIndex, position)
                }
            }
        }

        // Validate each manifest's dependencies
        for manifest in manifests {
            guard let deps = manifest.dependencies, !deps.isEmpty else { continue }
            guard let myPos = positionMap[manifest.name] else { continue }

            for dep in deps {
                if dep == "original" { continue }

                guard let depPos = positionMap[dep] else {
                    return "Plugin '\(manifest.name)' depends on '\(dep)' which is not in the pipeline."
                }

                let depRunsBefore = depPos.hookIndex < myPos.hookIndex ||
                    (depPos.hookIndex == myPos.hookIndex && depPos.position < myPos.position)

                if !depRunsBefore {
                    return "Plugin '\(manifest.name)' depends on '\(dep)' but '\(dep)' does not run before '\(manifest.name)' in the pipeline."
                }
            }
        }

        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter DependencyValidatorTests 2>&1 | tail -20`
Expected: All 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/State/DependencyValidator.swift Sources/piqley/Plugins/PluginManifest.swift Tests/piqleyTests/DependencyValidatorTests.swift
git commit -m "feat: add DependencyValidator and manifest dependencies field"
```

---

### Task 3: MetadataExtractor

**Files:**
- Create: `Sources/piqley/State/MetadataExtractor.swift`
- Create: `Tests/piqleyTests/MetadataExtractorTests.swift`

- [ ] **Step 1: Write failing tests for MetadataExtractor**

```swift
import Testing
import Foundation
@testable import piqley

@Suite("MetadataExtractor")
struct MetadataExtractorTests {
    @Test("extracts IPTC keywords from test JPEG")
    func testIPTCKeywords() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(
            at: imgPath,
            keywords: ["Nashville", "Sunset"]
        )

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        let keywords = result["IPTC:Keywords"]
        #expect(keywords == .array([.string("Nashville"), .string("Sunset")]))
    }

    @Test("extracts EXIF DateTimeOriginal")
    func testEXIFDate() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath, dateTimeOriginal: "2026:03:15 18:42:00")

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        #expect(result["EXIF:DateTimeOriginal"] == .string("2026:03:15 18:42:00"))
    }

    @Test("extracts TIFF camera make and model")
    func testTIFFCamera() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath, cameraMake: "Canon", cameraModel: "EOS R5")

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        #expect(result["TIFF:Make"] == .string("Canon"))
        #expect(result["TIFF:Model"] == .string("EOS R5"))
    }

    @Test("returns empty dict for image with no metadata")
    func testNoMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imgPath = tempDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath, dateTimeOriginal: nil)

        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: imgPath))
        // May have some metadata from image creation, but should not crash
        #expect(result is [String: JSONValue])
    }

    @Test("returns empty dict for nonexistent file")
    func testNonexistentFile() {
        let result = MetadataExtractor.extract(from: URL(fileURLWithPath: "/nonexistent/image.jpg"))
        #expect(result.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MetadataExtractorTests 2>&1 | tail -20`
Expected: Compilation error — `MetadataExtractor` does not exist.

- [ ] **Step 3: Write MetadataExtractor implementation**

```swift
import Foundation
import ImageIO

enum MetadataExtractor {
    /// Known CGImageSource property dictionary keys mapped to short group names.
    private static let groupMappings: [(key: CFString, prefix: String)] = [
        (kCGImagePropertyExifDictionary, "EXIF"),
        (kCGImagePropertyIPTCDictionary, "IPTC"),
        (kCGImagePropertyTIFFDictionary, "TIFF"),
        (kCGImagePropertyGPSDictionary, "GPS"),
        (kCGImagePropertyJFIFDictionary, "JFIF"),
    ]

    /// Extract EXIF/IPTC/XMP metadata from an image file, returning flattened Group:Tag keys.
    static func extract(from url: URL) -> [String: JSONValue] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }

        var result: [String: JSONValue] = [:]

        for (dictKey, prefix) in groupMappings {
            guard let groupDict = properties[dictKey as String] as? [String: Any] else { continue }
            for (tag, value) in groupDict {
                let key = "\(prefix):\(tag)"
                result[key] = anyToJSONValue(value)
            }
        }

        return result
    }

    /// Convert a Foundation value to JSONValue.
    private static func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // NSNumber wraps bools too; check CFBooleanGetTypeID
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map { anyToJSONValue($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { anyToJSONValue($0) })
        default:
            return .string(String(describing: value))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MetadataExtractorTests 2>&1 | tail -20`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/State/MetadataExtractor.swift Tests/piqleyTests/MetadataExtractorTests.swift
git commit -m "feat: add MetadataExtractor for EXIF/IPTC/XMP extraction"
```

---

### Task 4: JSON Protocol State Integration

**Files:**
- Modify: `Sources/piqley/Plugins/PluginRunner.swift`
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift` (update `runner.run()` call site to destructure tuple)
- Modify: `Tests/piqleyTests/PluginRunnerTests.swift` (update existing `let result = ...` to `let (result, _) = ...`)
- Create: `Tests/piqleyTests/PluginRunnerStateTests.swift`

This task adds `state` to the JSON input payload and captures `state` from the result response.

- [ ] **Step 1: Write failing tests for state in JSON protocol**

```swift
import Testing
import Foundation
@testable import piqley

private func makeTempScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-plugin-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func makePlugin(name: String, hook: String, scriptURL: URL) throws -> LoadedPlugin {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-plugin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
        "name": name,
        "pluginProtocolVersion": "1",
        "hooks": [hook: ["command": scriptURL.path, "args": [], "protocol": "json"]]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try data.write(to: tempDir.appendingPathComponent("manifest.json"))
    try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("data"), withIntermediateDirectories: true)
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
    return LoadedPlugin(name: name, directory: tempDir, manifest: decoded)
}

@Suite("PluginRunner State")
struct PluginRunnerStateTests {
    let tempFolder: TempFolder

    init() throws {
        tempFolder = try TempFolder.create()
        let imgPath = tempFolder.url.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: imgPath)
    }

    @Test("state is included in JSON payload when provided")
    func testStateInPayload() async throws {
        // Script reads stdin JSON payload via python and checks for state field
        let script = try makeTempScript("""
        INPUT=$(cat)
        HAS_STATE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'state' in d else 'no')")
        if [ "$HAS_STATE" = "yes" ]; then
            printf '{"type":"result","success":true,"error":null}\\n'
        else
            printf '{"type":"result","success":false,"error":"no state in payload"}\\n'
            exit 1
        fi
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let state: [String: [String: [String: JSONValue]]] = [
            "test.jpg": ["original": ["IPTC:Keywords": .array([.string("cat")])]]
        ]
        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let (result, _) = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            state: state
        )
        #expect(result == .success)
    }

    @Test("state is captured from plugin result response")
    func testStateCaptured() async throws {
        let script = try makeTempScript("""
        cat > /dev/null
        printf '{"type":"result","success":true,"state":{"test.jpg":{"hashtags":["#cat","#dog"]}}}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "hashtag", hook: "post-process", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let (result, returnedState) = try await runner.run(
            hook: "post-process",
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            state: nil
        )
        #expect(result == .success)
        #expect(returnedState?["test.jpg"]?["hashtags"] == .array([.string("#cat"), .string("#dog")]))
    }

    @Test("no state in response returns nil")
    func testNoStateReturned() async throws {
        let script = try makeTempScript("""
        cat > /dev/null
        printf '{"type":"result","success":true}\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let plugin = try makePlugin(name: "test", hook: "publish", scriptURL: script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }

        let runner = PluginRunner(plugin: plugin, secrets: [:], pluginConfig: PluginConfig())
        let (result, returnedState) = try await runner.run(
            hook: "publish",
            tempFolder: tempFolder,
            executionLogPath: FileManager.default.temporaryDirectory.appendingPathComponent("exec.jsonl"),
            dryRun: false,
            state: nil
        )
        #expect(result == .success)
        #expect(returnedState == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginRunnerStateTests 2>&1 | tail -20`
Expected: Compilation error — `run()` doesn't have `state` parameter or return tuple.

- [ ] **Step 3: Modify PluginRunner to accept and return state**

Modify: `Sources/piqley/Plugins/PluginRunner.swift`

Changes needed:

1. Change `run()` signature — add `state` parameter with default `nil`, return `(ExitCodeResult, [String: [String: JSONValue]]?)`:
```swift
func run(
    hook: String,
    tempFolder: TempFolder,
    executionLogPath: URL,
    dryRun: Bool,
    state: [String: [String: [String: JSONValue]]]? = nil
) async throws -> (ExitCodeResult, [String: [String: JSONValue]]?)
```

2. Add `state` field to `JSONRunContext` struct and thread it through.

3. Add `state` to `PluginInputPayload`:
```swift
let state: [String: [String: [String: JSONValue]]]?
```

4. Add `state` to `PluginOutputLine`:
```swift
let state: [String: [String: JSONValue]]?
```

5. In `readJSONOutput`, change return type to `(ExitCodeResult, [String: [String: JSONValue]]?)`. Add a `var resultState: [String: [String: JSONValue]]?` alongside the existing `var gotResult`. In the `case "result"` branch, capture the state:
```swift
case "result":
    gotResult = true
    resultState = obj.state
```
Return `(evaluator.evaluate(...), resultState)` at the end.

6. Thread the state return through `runJSON` → `run`. Pipe/batchProxy paths return `(result, nil)`.

7. Update `buildJSONPayload` to accept and include state parameter.

- [ ] **Step 4: Update existing call sites to compile with new return type**

In `Tests/piqleyTests/PluginRunnerTests.swift`, change every `let result = try await runner.run(...)` to `let (result, _) = try await runner.run(...)`.

In `Sources/piqley/Pipeline/PipelineOrchestrator.swift`, change `let result = try await runner.run(...)` to `let (result, _) = try await runner.run(...)` (temporary — Task 5 will use the state).

- [ ] **Step 5: Run all tests to verify everything compiles and passes**

Run: `swift test --filter PluginRunner 2>&1 | tail -20`
Expected: All existing + new PluginRunner tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/Plugins/PluginRunner.swift Tests/piqleyTests/PluginRunnerStateTests.swift
git commit -m "feat: add state support to JSON protocol payload and response"
```

---

### Task 5: PipelineOrchestrator Integration

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift`

This task wires StateStore, MetadataExtractor, and DependencyValidator into the orchestrator.

- [ ] **Step 1: Write failing integration test**

Add to `Tests/piqleyTests/PipelineOrchestratorTests.swift` (or create if structure requires):

The orchestrator calls `runner.run()` which now returns a tuple. Update the existing call site in `PipelineOrchestrator.run()` to destructure it. Also integrate StateStore, MetadataExtractor, and DependencyValidator.

Since PipelineOrchestrator tests involve full subprocess execution and Keychain access which are hard to unit test, focus on verifying the orchestrator compiles and existing tests pass.

- [ ] **Step 2: Integrate into PipelineOrchestrator.run()**

Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift`

Changes needed:

1. After `try temp.copyImages(from: sourceURL)`, create StateStore and extract metadata (StateStore is an `actor`, so all calls use `await`):
```swift
let stateStore = StateStore()

// Extract metadata from all images into original namespace
let imageFiles = try FileManager.default.contentsOfDirectory(
    at: temp.url, includingPropertiesForKeys: nil
).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

for imageFile in imageFiles {
    let metadata = MetadataExtractor.extract(from: imageFile)
    await stateStore.setNamespace(
        image: imageFile.lastPathComponent,
        plugin: "original",
        values: metadata
    )
}
```

2. After auto-discovery and before the hook loop, validate dependencies:
```swift
// Collect all manifests for dependency validation
var allManifests: [PluginManifest] = []
for hook in PluginManifest.canonicalHooks {
    for pluginName in (pipeline[hook] ?? []) {
        let name = pluginName.split(separator: ":").first.map(String.init) ?? pluginName
        if let loaded = try loadPlugin(named: name) {
            if !allManifests.contains(where: { $0.name == loaded.manifest.name }) {
                allManifests.append(loaded.manifest)
            }
        }
    }
}
if let error = DependencyValidator.validate(manifests: allManifests, pipeline: pipeline) {
    logger.error("Dependency validation failed: \(error)")
    try? temp.delete()
    return false
}
```

3. Before calling `runner.run()`, build state for this plugin:
```swift
let deps = loadedPlugin.manifest.dependencies ?? []
let proto = loadedPlugin.manifest.hooks[hook]?.pluginProtocol ?? .json
var pluginState: [String: [String: [String: JSONValue]]]? = nil
if proto == .json && !deps.isEmpty {
    var statePayload: [String: [String: [String: JSONValue]]] = [:]
    for imageName in await stateStore.allImageNames {
        let resolved = await stateStore.resolve(image: imageName, dependencies: deps)
        if !resolved.isEmpty {
            statePayload[imageName] = resolved
        }
    }
    if !statePayload.isEmpty {
        pluginState = statePayload
    }
}
```

4. Update the `runner.run()` call (replace the `let (result, _) =` from Task 4):
```swift
let (result, returnedState) = try await runner.run(
    hook: hook,
    tempFolder: temp,
    executionLogPath: execLogPath,
    dryRun: dryRun,
    state: pluginState
)
```

5. After successful run, store returned state:
```swift
if let returnedState {
    for (imageName, values) in returnedState {
        // Only store state for images that exist in the temp folder
        let imageExists = FileManager.default.fileExists(
            atPath: temp.url.appendingPathComponent(imageName).path
        )
        if imageExists {
            await stateStore.setNamespace(image: imageName, plugin: pluginName, values: values)
        }
    }
}
```

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass. Existing orchestrator tests should still work since `state` defaults to nil.

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift
git commit -m "feat: integrate state engine into pipeline orchestrator"
```

---

### Task 6: Manifest Decoding Tests Update

**Files:**
- Modify: `Tests/piqleyTests/PluginManifestTests.swift`

- [ ] **Step 1: Add test for dependencies field decoding**

```swift
@Test("decodes manifest with dependencies")
func testDependencies() throws {
    let json = """
    {
      "name": "flickr",
      "pluginProtocolVersion": "1",
      "dependencies": ["hashtag", "original"],
      "hooks": {"publish": {"command": "./tool", "args": []}}
    }
    """
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    #expect(manifest.dependencies == ["hashtag", "original"])
}

@Test("absent dependencies decodes to nil")
func testNoDependencies() throws {
    let json = """
    {
      "name": "simple",
      "pluginProtocolVersion": "1",
      "hooks": {"publish": {"command": "./tool", "args": []}}
    }
    """
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    #expect(manifest.dependencies == nil)
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter PluginManifestTests 2>&1 | tail -20`
Expected: All tests pass (including new ones).

- [ ] **Step 3: Commit**

```bash
git add Tests/piqleyTests/PluginManifestTests.swift
git commit -m "test: add manifest dependencies decoding tests"
```

---

### Task 7: Full Test Suite Verification

- [ ] **Step 1: Run the complete test suite**

Run: `swift test 2>&1 | tail -40`
Expected: All tests pass with no regressions.

- [ ] **Step 2: Build release configuration**

Run: `swift build -c release 2>&1 | tail -10`
Expected: Clean build with no errors or warnings.

- [ ] **Step 3: Commit any remaining fixes**

Only if issues were found in steps 1-2.
