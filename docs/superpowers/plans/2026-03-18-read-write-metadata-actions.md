# Read/Write Metadata Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable declarative rules to read current image file metadata via the `read:` namespace and write metadata back to files via `write` actions on rules.

**Architecture:** Add `write` array to `Rule` (PiqleyCore), `MetadataBuffer` actor for lazy extraction and batched write-back (CLI), `MetadataWriter` for CGImageDestination write-back (macOS), make `RuleEvaluator.evaluate` async to interact with the buffer actor, add `MatchField.read()` factory (SDK).

**Tech Stack:** Swift 6, Swift Testing, CoreGraphics ImageIO, PiqleyCore, PiqleyPluginSDK, piqley-cli

**Spec:** `docs/superpowers/specs/2026-03-18-read-write-metadata-actions-design.md`

---

### Task 1: Add `write` to Rule in PiqleyCore

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Sources/PiqleyCore/Config/Rule.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-core/Tests/PiqleyCoreTests/ConfigCodingTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `ConfigCodingTests.swift`:

```swift
@Test func decodeRuleWithWrite() throws {
    let json = """
    {
        "match": {"field": "original:TIFF:Model", "pattern": "Canon"},
        "emit": [{"field": "keywords", "values": ["canon"]}],
        "write": [{"action": "add", "field": "IPTC:Keywords", "values": ["canon"]}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.write.count == 1)
    #expect(rule.write[0].action == "add")
    #expect(rule.write[0].field == "IPTC:Keywords")
}

@Test func decodeRuleWithoutWriteDefaultsEmpty() throws {
    let json = """
    {
        "match": {"field": "title", "pattern": ".*"},
        "emit": [{"field": "keywords", "values": ["any"]}]
    }
    """
    let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
    #expect(rule.write.isEmpty)
}

@Test func encodeRoundTripRuleWithWrite() throws {
    let rule = Rule(
        match: MatchConfig(field: "title", pattern: "test"),
        emit: [EmitConfig(field: "keywords", values: ["a"])],
        write: [EmitConfig(action: "remove", field: "IPTC:Keywords", values: ["old"])]
    )
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(Rule.self, from: data)
    #expect(decoded.write.count == 1)
    #expect(decoded.write[0].action == "remove")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter ConfigCodingTests 2>&1 | tail -20`

- [ ] **Step 3: Update Rule struct**

In `Rule.swift`, update `Rule`:

```swift
public struct Rule: Codable, Sendable, Equatable {
    public let match: MatchConfig
    public let emit: [EmitConfig]
    public let write: [EmitConfig]

    public init(match: MatchConfig, emit: [EmitConfig], write: [EmitConfig] = []) {
        self.match = match
        self.emit = emit
        self.write = write
    }

    private enum CodingKeys: String, CodingKey {
        case match, emit, write
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decode(MatchConfig.self, forKey: .match)
        emit = try container.decode([EmitConfig].self, forKey: .emit)
        write = try container.decodeIfPresent([EmitConfig].self, forKey: .write) ?? []
    }
}
```

- [ ] **Step 4: Run all PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Config/Rule.swift Tests/PiqleyCoreTests/ConfigCodingTests.swift
git commit -m "feat: add write array to Rule for metadata write actions"
```

---

### Task 2: Add `MatchField.read()` and `ConfigRule.write` in PiqleyPluginSDK

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/MatchField.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-plugin-sdk/swift/Tests/ConfigBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `ConfigBuilderTests.swift`:

```swift
@Test func matchFieldRead() {
    let field = MatchField.read("IPTC:Keywords")
    #expect(field.encoded == "read:IPTC:Keywords")
}

@Test func configRuleWithWrite() {
    let config = buildConfig {
        Rules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Canon")),
                emit: [.keywords(["canon"])],
                write: [.values(field: "IPTC:Keywords", ["canon"])]
            )
        }
    }
    #expect(config.rules[0].write.count == 1)
    #expect(config.rules[0].write[0].field == "IPTC:Keywords")
    #expect(config.rules[0].write[0].values == ["canon"])
}

@Test func configRuleWriteOnly() {
    let config = buildConfig {
        Rules {
            ConfigRule(
                match: .field(.read("IPTC:Keywords"), pattern: .glob("*landscape*")),
                write: [.remove(field: "IPTC:Keywords", ["glob:temp-*"])]
            )
        }
    }
    #expect(config.rules[0].match.field == "read:IPTC:Keywords")
    #expect(config.rules[0].emit.isEmpty)
    #expect(config.rules[0].write.count == 1)
}

@Test func configRuleDefaultsWriteToEmpty() {
    let config = buildConfig {
        Rules {
            ConfigRule(
                match: .field(.original(.model), pattern: .exact("Sony")),
                emit: [.keywords(["sony"])]
            )
        }
    }
    #expect(config.rules[0].write.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter ConfigBuilderTests 2>&1 | tail -20`

- [ ] **Step 3: Add `MatchField.read()` factory**

In `MatchField.swift`, add:

```swift
/// Match against current image file metadata (read: namespace).
public static func read(_ key: String) -> MatchField {
    MatchField(encoded: "read:\(key)")
}
```

- [ ] **Step 4: Update ConfigRule to include write**

In `ConfigBuilder.swift`, update `ConfigRule`:

```swift
public struct ConfigRule: Sendable {
    let match: RuleMatch
    let emit: [RuleEmit]
    let write: [RuleEmit]

    public init(match: RuleMatch, emit: [RuleEmit] = [], write: [RuleEmit] = []) {
        self.match = match
        self.emit = emit
        self.write = write
    }

    func toRule() -> Rule {
        Rule(
            match: match.toMatchConfig(),
            emit: emit.map { $0.toEmitConfig() },
            write: write.map { $0.toEmitConfig() }
        )
    }
}
```

- [ ] **Step 5: Run all SDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add swift/PiqleyPluginSDK/Builders/MatchField.swift swift/PiqleyPluginSDK/Builders/ConfigBuilder.swift swift/Tests/ConfigBuilderTests.swift
git commit -m "feat: add MatchField.read() and ConfigRule.write for metadata I/O"
```

---

### Task 3: Create MetadataWriter

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/MetadataWriter.swift`
- Create: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/MetadataWriterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/MetadataWriterTests.swift`:

```swift
import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("MetadataWriter")
struct MetadataWriterTests {

    @Test("write and read-back IPTC keywords")
    func writeIPTCKeywords() throws {
        let (url, cleanup) = try makeTestImage()
        defer { cleanup() }

        let original = MetadataExtractor.extract(from: url)

        var metadata = original
        metadata["IPTC:Keywords"] = .array([.string("test-keyword"), .string("piqley")])

        try MetadataWriter.write(metadata: metadata, to: url)

        let updated = MetadataExtractor.extract(from: url)
        #expect(updated["IPTC:Keywords"] == .array([.string("test-keyword"), .string("piqley")]))
    }

    @Test("write preserves existing unmodified metadata")
    func writePreservesExisting() throws {
        let (url, cleanup) = try makeTestImage()
        defer { cleanup() }

        let original = MetadataExtractor.extract(from: url)
        let originalModel = original["TIFF:Model"]

        var metadata = original
        metadata["IPTC:Keywords"] = .array([.string("new-tag")])

        try MetadataWriter.write(metadata: metadata, to: url)

        let updated = MetadataExtractor.extract(from: url)
        #expect(updated["TIFF:Model"] == originalModel)
    }

    @Test("write to nonexistent file throws")
    func writeNonexistentThrows() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).jpg")
        #expect(throws: MetadataWriteError.self) {
            try MetadataWriter.write(metadata: [:], to: url)
        }
    }

    /// Creates a minimal JPEG in a temp directory for testing.
    private func makeTestImage() throws -> (URL, () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Use a test fixture if available, otherwise create minimal JPEG
        let fixturesDir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures")
        if let fixture = fixturesDir?.appendingPathComponent("test.jpg"),
           FileManager.default.fileExists(atPath: fixture.path) {
            let dest = tempDir.appendingPathComponent("test.jpg")
            try FileManager.default.copyItem(at: fixture, to: dest)
            return (dest, { try? FileManager.default.removeItem(at: tempDir) })
        }

        // Create a minimal 1x1 JPEG with CGImage
        let dest = tempDir.appendingPathComponent("test.jpg")
        try createMinimalJPEG(at: dest)
        return (dest, { try? FileManager.default.removeItem(at: tempDir) })
    }

    private func createMinimalJPEG(at url: URL) throws {
        #if canImport(CoreGraphics)
            import CoreGraphics
            import ImageIO
            import UniformTypeIdentifiers

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ), let image = ctx.makeImage() else {
                throw MetadataWriteError.sourceCreationFailed
            }

            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else {
                throw MetadataWriteError.destinationCreationFailed
            }

            let properties: [String: Any] = [
                kCGImagePropertyTIFFDictionary as String: [
                    kCGImagePropertyTIFFModel as String: "TestCamera"
                ]
            ]
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw MetadataWriteError.finalizeFailed
            }
        #endif
    }
}
```

Note: The `createMinimalJPEG` helper may need adjustment at implementation time — the `import` inside `#if` might need to be at file level. Move imports to the top of the file if needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter MetadataWriterTests 2>&1 | tail -20`

Expected: compilation error (MetadataWriter doesn't exist)

- [ ] **Step 3: Implement MetadataWriter**

Create `Sources/piqley/State/MetadataWriter.swift`:

```swift
#if canImport(ImageIO)
    import Foundation
    import ImageIO
    import PiqleyCore
    import UniformTypeIdentifiers

    enum MetadataWriteError: Error, LocalizedError {
        case sourceCreationFailed
        case destinationCreationFailed
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .sourceCreationFailed: "Failed to create image source"
            case .destinationCreationFailed: "Failed to create image destination"
            case .finalizeFailed: "Failed to finalize image write"
            }
        }
    }

    enum MetadataWriter {
        /// Known group prefixes mapped to CGImageSource property dictionary keys.
        private static let groupMappings: [(prefix: String, key: CFString)] = [
            ("EXIF", kCGImagePropertyExifDictionary),
            ("IPTC", kCGImagePropertyIPTCDictionary),
            ("TIFF", kCGImagePropertyTIFFDictionary),
            ("GPS", kCGImagePropertyGPSDictionary),
            ("JFIF", kCGImagePropertyJFIFDictionary),
        ]

        /// Write metadata to an image file. Copies image data as-is, only modifies metadata.
        static func write(metadata: [String: JSONValue], to url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw MetadataWriteError.sourceCreationFailed
            }

            guard let uti = CGImageSourceGetType(source) else {
                throw MetadataWriteError.sourceCreationFailed
            }

            // Build nested properties dictionary from flat Group:Key format
            let properties = buildProperties(from: metadata)

            // Write to temp file then replace
            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp")

            guard let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL, uti, CGImageSourceGetCount(source), nil
            ) else {
                throw MetadataWriteError.destinationCreationFailed
            }

            for index in 0 ..< CGImageSourceGetCount(source) {
                CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
            }

            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw MetadataWriteError.finalizeFailed
            }

            try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        }

        /// Convert flat "Group:Key" metadata to nested CGImageProperties format.
        private static func buildProperties(from metadata: [String: JSONValue]) -> [String: Any] {
            var properties: [String: Any] = [:]

            for (prefix, dictKey) in groupMappings {
                var groupDict: [String: Any] = [:]
                let groupPrefix = "\(prefix):"

                for (key, value) in metadata where key.hasPrefix(groupPrefix) {
                    let tag = String(key.dropFirst(groupPrefix.count))
                    groupDict[tag] = jsonValueToAny(value)
                }

                if !groupDict.isEmpty {
                    properties[dictKey as String] = groupDict
                }
            }

            return properties
        }

        /// Convert JSONValue back to Foundation types for CGImageDestination.
        private static func jsonValueToAny(_ value: JSONValue) -> Any {
            switch value {
            case let .string(str): return str
            case let .number(num): return NSNumber(value: num)
            case let .bool(val): return NSNumber(value: val)
            case let .array(arr): return arr.map { jsonValueToAny($0) }
            case let .object(dict): return dict.mapValues { jsonValueToAny($0) }
            case .null: return NSNull()
            }
        }
    }
#else
    import Foundation
    import PiqleyCore

    enum MetadataWriteError: Error, LocalizedError {
        case sourceCreationFailed
        case destinationCreationFailed
        case finalizeFailed
        case platformUnsupported

        var errorDescription: String? {
            switch self {
            case .sourceCreationFailed: "Failed to create image source"
            case .destinationCreationFailed: "Failed to create image destination"
            case .finalizeFailed: "Failed to finalize image write"
            case .platformUnsupported: "Metadata writing is not available on this platform"
            }
        }
    }

    enum MetadataWriter {
        static func write(metadata _: [String: JSONValue], to _: URL) throws {
            // No-op on Linux
        }
    }
#endif
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter MetadataWriterTests 2>&1 | tail -20`

Expected: all tests pass (may need test fixture adjustments)

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/MetadataWriter.swift Tests/piqleyTests/MetadataWriterTests.swift
git commit -m "feat: add MetadataWriter for CGImageDestination metadata write-back"
```

---

### Task 4: Create MetadataBuffer actor

**Files:**
- Create: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/MetadataBuffer.swift`
- Create: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/MetadataBufferTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/MetadataBufferTests.swift`:

```swift
import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("MetadataBuffer")
struct MetadataBufferTests {

    @Test("load extracts metadata from file")
    func loadExtractsMetadata() async throws {
        let (url, cleanup) = try makeTestImage(model: "TestCamera")
        defer { cleanup() }

        let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
        let metadata = await buffer.load(image: url.lastPathComponent)
        #expect(metadata["TIFF:Model"] == .string("TestCamera"))
    }

    @Test("load caches result on second call")
    func loadCachesResult() async throws {
        let (url, cleanup) = try makeTestImage(model: "TestCamera")
        defer { cleanup() }

        let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
        let first = await buffer.load(image: url.lastPathComponent)
        let second = await buffer.load(image: url.lastPathComponent)
        #expect(first == second)
    }

    @Test("applyAction modifies cached metadata")
    func applyActionModifies() async throws {
        let (url, cleanup) = try makeTestImage(model: "TestCamera")
        defer { cleanup() }

        let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
        let action = EmitAction.add(field: "IPTC:Keywords", values: ["test-tag"])
        await buffer.applyAction(action, image: url.lastPathComponent)

        let metadata = await buffer.load(image: url.lastPathComponent)
        #expect(metadata["IPTC:Keywords"] == .array([.string("test-tag")]))
    }

    @Test("flush writes dirty images to disk")
    func flushWritesToDisk() async throws {
        let (url, cleanup) = try makeTestImage(model: "TestCamera")
        defer { cleanup() }

        let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
        let action = EmitAction.add(field: "IPTC:Keywords", values: ["flushed"])
        await buffer.applyAction(action, image: url.lastPathComponent)
        try await buffer.flush()

        // Re-read from disk to verify
        let fromDisk = MetadataExtractor.extract(from: url)
        #expect(fromDisk["IPTC:Keywords"] == .array([.string("flushed")]))
    }

    @Test("flush skips clean images")
    func flushSkipsClean() async throws {
        let (url, cleanup) = try makeTestImage(model: "TestCamera")
        defer { cleanup() }

        let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
        _ = await buffer.load(image: url.lastPathComponent)
        // No writes, so flush should be a no-op
        try await buffer.flush()
        // No error = success
    }

    @Test("load returns empty for unknown image")
    func loadUnknownImage() async {
        let buffer = MetadataBuffer(imageURLs: [:])
        let metadata = await buffer.load(image: "nonexistent.jpg")
        #expect(metadata.isEmpty)
    }
}
```

Note: `makeTestImage` helper needs to be shared with MetadataWriterTests or duplicated. At implementation time, consider extracting to a shared test helper file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter MetadataBufferTests 2>&1 | tail -20`

Expected: compilation error (MetadataBuffer doesn't exist)

- [ ] **Step 3: Implement MetadataBuffer**

Create `Sources/piqley/State/MetadataBuffer.swift`:

```swift
import Foundation
import Logging
import PiqleyCore

actor MetadataBuffer {
    private var metadata: [String: [String: JSONValue]] = [:]
    private var dirty: Set<String> = []
    private let imageURLs: [String: URL]
    private let logger = Logger(label: "piqley.metadata-buffer")

    init(imageURLs: [String: URL]) {
        self.imageURLs = imageURLs
    }

    /// Load metadata for an image. Extracts from disk on first call, returns cached on subsequent.
    func load(image: String) -> [String: JSONValue] {
        if let cached = metadata[image] {
            return cached
        }

        guard let url = imageURLs[image] else {
            return [:]
        }

        let extracted = MetadataExtractor.extract(from: url)
        metadata[image] = extracted
        return extracted
    }

    /// Apply a pre-compiled write action against an image's metadata.
    func applyAction(_ action: EmitAction, image: String) {
        // Ensure metadata is loaded before applying
        if metadata[image] == nil {
            _ = load(image: image)
        }

        var current = metadata[image] ?? [:]
        RuleEvaluator.applyAction(action, to: &current)
        metadata[image] = current
        dirty.insert(image)
    }

    /// Flush all dirty images to disk.
    func flush() throws {
        for imageName in dirty {
            guard let url = imageURLs[imageName],
                  let imageMetadata = metadata[imageName]
            else { continue }

            do {
                try MetadataWriter.write(metadata: imageMetadata, to: url)
            } catch {
                logger.error("Failed to write metadata for \(imageName): \(error.localizedDescription)")
            }
        }
        dirty.removeAll()
    }
}
```

Note: This requires `RuleEvaluator.applyAction` to become `static` (non-private). See Task 5.

- [ ] **Step 4: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter MetadataBufferTests 2>&1 | tail -20`

Expected: may fail due to `applyAction` visibility — that's fixed in Task 5

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/MetadataBuffer.swift Tests/piqleyTests/MetadataBufferTests.swift
git commit -m "feat: add MetadataBuffer actor for lazy extraction and batched write-back"
```

---

### Task 5: Make RuleEvaluator async, add write support and read: namespace

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/State/RuleEvaluator.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing tests for read: and write**

Add to `RuleEvaluatorTests.swift`:

```swift
// MARK: - Read namespace

@Test("read: namespace resolves from MetadataBuffer")
func readNamespaceFromBuffer() async throws {
    let (url, cleanup) = try makeTestImage(model: "CanonEOS")
    defer { cleanup() }

    let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "read:TIFF:Model",
            pattern: "glob:Canon*",
            emit: [EmitConfig(field: "keywords", values: ["canon"])]
        )],
        logger: logger
    )
    let result = await evaluator.evaluate(
        hook: "pre-process",
        state: [:],
        metadataBuffer: buffer,
        imageName: url.lastPathComponent
    )
    #expect(result["keywords"] == .array([.string("canon")]))
}

@Test("read: namespace no match when metadata absent")
func readNamespaceNoMatch() async throws {
    let buffer = MetadataBuffer(imageURLs: [:])
    let evaluator = try RuleEvaluator(
        rules: [makeRule(
            field: "read:TIFF:Model",
            pattern: "Canon",
            emit: [EmitConfig(field: "keywords", values: ["canon"])]
        )],
        logger: logger
    )
    let result = await evaluator.evaluate(
        hook: "pre-process",
        state: [:],
        metadataBuffer: buffer,
        imageName: "missing.jpg"
    )
    #expect(result.isEmpty)
}

// MARK: - Write actions

@Test("write actions applied to MetadataBuffer")
func writeActionsApplied() async throws {
    let (url, cleanup) = try makeTestImage(model: "TestCamera")
    defer { cleanup() }

    let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
    let evaluator = try RuleEvaluator(
        rules: [Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "TestCamera"),
            emit: [EmitConfig(field: "keywords", values: ["tagged"])],
            write: [EmitConfig(action: "add", field: "IPTC:Keywords", values: ["written"])]
        )],
        logger: logger
    )
    let result = await evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("TestCamera")]],
        metadataBuffer: buffer,
        imageName: url.lastPathComponent
    )
    #expect(result["keywords"] == .array([.string("tagged")]))

    // Verify buffer has the write action applied
    let bufferMetadata = await buffer.load(image: url.lastPathComponent)
    #expect(bufferMetadata["IPTC:Keywords"] == .array([.string("written")]))
}

@Test("write-only rule with no emit")
func writeOnlyRule() async throws {
    let (url, cleanup) = try makeTestImage(model: "TestCamera")
    defer { cleanup() }

    let buffer = MetadataBuffer(imageURLs: [url.lastPathComponent: url])
    let evaluator = try RuleEvaluator(
        rules: [Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "TestCamera"),
            emit: [],
            write: [EmitConfig(action: "add", field: "IPTC:Keywords", values: ["auto-tag"])]
        )],
        logger: logger
    )
    let result = await evaluator.evaluate(
        hook: "pre-process",
        state: ["original": ["TIFF:Model": .string("TestCamera")]],
        metadataBuffer: buffer,
        imageName: url.lastPathComponent
    )
    #expect(result.isEmpty)

    let bufferMetadata = await buffer.load(image: url.lastPathComponent)
    #expect(bufferMetadata["IPTC:Keywords"] == .array([.string("auto-tag")]))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests 2>&1 | tail -20`

- [ ] **Step 3: Update RuleEvaluator**

Key changes to `RuleEvaluator.swift`:

1. Make `applyAction` `static` (not `private static`) so `MetadataBuffer` can call it.

2. Add `writeActions: [EmitAction]` to `CompiledRule`. Compile `rule.write` entries in `init` using the same `compileEmitAction` method.

3. Make `evaluate` `async` and add `metadataBuffer` + `imageName` parameters:

```swift
func evaluate(
    hook: String,
    state: [String: [String: JSONValue]],
    currentNamespace: [String: JSONValue] = [:],
    metadataBuffer: MetadataBuffer? = nil,
    imageName: String? = nil
) async -> [String: JSONValue]
```

4. In the match resolution, when `namespace == "read"` and `metadataBuffer != nil` and `imageName != nil`:
   - Call `await metadataBuffer.load(image: imageName)` to get metadata
   - Look up the field in the returned dictionary

5. After applying `emitActions`, apply `writeActions` to the buffer:
   - For each write action, call `await metadataBuffer.applyAction(action, image: imageName)`

6. Emit actions run before write actions within a matched rule.

- [ ] **Step 4: Update existing tests to use async evaluate**

All existing `evaluator.evaluate(...)` calls need `await` prepended. Tests that don't use buffer can pass `nil` (the default).

- [ ] **Step 5: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter RuleEvaluatorTests 2>&1 | tail -20`

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/State/RuleEvaluator.swift Tests/piqleyTests/RuleEvaluatorTests.swift
git commit -m "feat: make evaluate async, add read: namespace and write action support"
```

---

### Task 6: Update PipelineOrchestrator

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/Pipeline/PipelineOrchestrator.swift`

- [ ] **Step 1: Add imageFiles to HookContext or evaluateRules**

The `evaluateRules` method needs access to image file URLs to create `MetadataBuffer`. Either add `imageFiles: [URL]` to `HookContext` or pass it as a parameter to `evaluateRules`.

Update `HookContext`:

```swift
private struct HookContext {
    let pluginName: String
    let hook: String
    let temp: TempFolder
    let stateStore: StateStore
    let imageFiles: [URL]
    let dryRun: Bool
    let nonInteractive: Bool
}
```

Update the `HookContext` construction to pass `imageFiles`.

- [ ] **Step 2: Update evaluateRules to use MetadataBuffer**

```swift
private func evaluateRules(
    _ ctx: HookContext,
    manifestDeps: [String],
    pluginConfig: PluginConfig,
    ruleEvaluatorCache: inout [String: RuleEvaluator]
) async throws -> Bool {
    guard !pluginConfig.rules.isEmpty else { return false }

    let evaluator: RuleEvaluator
    if let cached = ruleEvaluatorCache[ctx.pluginName] {
        evaluator = cached
    } else {
        evaluator = try RuleEvaluator(
            rules: pluginConfig.rules,
            nonInteractive: ctx.nonInteractive,
            logger: logger
        )
        ruleEvaluatorCache[ctx.pluginName] = evaluator
    }

    let imageURLs = Dictionary(uniqueKeysWithValues: ctx.imageFiles.map {
        ($0.lastPathComponent, $0)
    })
    let buffer = MetadataBuffer(imageURLs: imageURLs)

    var didRun = false
    for imageName in await ctx.stateStore.allImageNames {
        let resolved = await ctx.stateStore.resolve(
            image: imageName, dependencies: manifestDeps + [ReservedName.original, ctx.pluginName]
        )
        let currentNamespace = resolved[ctx.pluginName] ?? [:]
        let ruleOutput = await evaluator.evaluate(
            hook: ctx.hook, state: resolved, currentNamespace: currentNamespace,
            metadataBuffer: buffer, imageName: imageName
        )
        if ruleOutput != currentNamespace {
            await ctx.stateStore.setNamespace(
                image: imageName, plugin: ctx.pluginName, values: ruleOutput
            )
            didRun = true
        }
    }

    try await buffer.flush()
    return didRun
}
```

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift
git commit -m "feat: integrate MetadataBuffer into PipelineOrchestrator"
```

---

### Task 7: Update remaining CLI tests and PluginCommand examples

**Files:**
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/RuleTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Tests/piqleyTests/PluginConfigTests.swift`
- Modify: `/Users/wash/Developer/tools/piqley/piqley-cli/Sources/piqley/CLI/PluginCommand.swift`

- [ ] **Step 1: Update RuleTests for write array**

Update JSON in tests to include `"write": []` where needed, or verify that missing `write` decodes to empty array.

- [ ] **Step 2: Update PluginConfigTests**

Update `Rule` construction to include `write: []` where needed.

- [ ] **Step 3: Add a write example to plugin init**

In `PluginCommand.swift`, add one `ConfigRule` example using `write`:

```swift
// Write keywords back to image file
ConfigRule(
    match: .field(
        .original(.make),
        pattern: .glob("*Canon*"),
        hook: .postProcess
    ),
    emit: [.keywords(["Canon"])],
    write: [.values(field: "IPTC:Keywords", ["Canon", "piqley-processed"])]
)
```

- [ ] **Step 4: Run full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -30`

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Tests/piqleyTests/RuleTests.swift Tests/piqleyTests/PluginConfigTests.swift Sources/piqley/CLI/PluginCommand.swift
git commit -m "feat: update tests and plugin init examples with write actions"
```

---

### Task 8: Final cross-repo verification

- [ ] **Step 1: Run PiqleyCore tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`

- [ ] **Step 2: Run PiqleyPluginSDK tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`

- [ ] **Step 3: Run piqley-cli tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test 2>&1 | tail -20`

- [ ] **Step 4: Build release**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build -c release 2>&1 | tail -10`

Expected: all pass, clean build
