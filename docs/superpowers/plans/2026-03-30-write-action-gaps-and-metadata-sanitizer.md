# Write Action Gaps and Metadata Sanitizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable clone and template resolution in write actions, then create a metadata sanitizer plugin that uses them to strip non-allowed fields from images.

**Architecture:** Two gaps in `RuleEvaluator.evaluate()` are fixed: write actions now go through `resolveTemplates()` and clone is handled inline (mirroring the emit path). `MetadataBuffer` gets two new methods (`applyClone`, `applyCloneAll`) for merging resolved values into image metadata. The sanitizer plugin is a rules-only mutable plugin with two unconditional rules: wipe all file metadata, then clone back 17 allowed fields from `original:`.

**Tech Stack:** Swift, Swift Testing framework, PiqleyCore, piqley CLI

**Spec:** `docs/superpowers/specs/2026-03-30-write-action-gaps-and-metadata-sanitizer-design.md`

---

### Task 1: Template Resolution for Write Actions

**Files:**
- Modify: `Sources/piqley/State/RuleEvaluator.swift:337-342`
- Test: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/piqleyTests/RuleEvaluatorTests.swift`:

```swift
@Test("write add action resolves templates from state")
func writeAddResolveTemplate() async throws {
    let rule = Rule(
        match: nil,
        emit: [],
        write: [EmitConfig(
            action: "add", field: "EXIF:FNumber",
            values: ["{{original:EXIF:FNumber}}"],
            replacements: nil, source: nil
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let buffer = MetadataBuffer(preloaded: [
        "img.jpg": ["EXIF:FNumber": .string("old")]
    ])
    _ = await evaluator.evaluate(
        state: ["original": ["EXIF:FNumber": .string("f/2.8")]],
        metadataBuffer: buffer,
        imageName: "img.jpg"
    )
    let meta = await buffer.load(image: "img.jpg")
    #expect(meta["EXIF:FNumber"] == .array([.string("old"), .string("f/2.8")]))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter writeAddResolveTemplate`
Expected: FAIL. The template `{{original:EXIF:FNumber}}` is passed as a literal string because write actions skip `resolveTemplates`.

- [ ] **Step 3: Add template resolution to write action loop**

In `Sources/piqley/State/RuleEvaluator.swift`, replace lines 337-342:

```swift
// Write actions second (modify file metadata via buffer)
if let buffer = metadataBuffer, let image = imageName {
    for action in rule.writeActions {
        await buffer.applyAction(action, image: image)
    }
}
```

With:

```swift
// Write actions second (modify file metadata via buffer)
if let buffer = metadataBuffer, let image = imageName {
    for action in rule.writeActions {
        let resolvedAction = await resolveTemplates(
            in: action,
            state: state,
            metadataBuffer: metadataBuffer,
            imageName: imageName,
            pluginId: pluginId
        )
        await buffer.applyAction(resolvedAction, image: image)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter writeAddResolveTemplate`
Expected: PASS

- [ ] **Step 5: Commit**

Message: `feat: add template resolution for write actions`

---

### Task 2: Single-Field Clone in Write Actions

**Files:**
- Modify: `Sources/piqley/State/MetadataBuffer.swift`
- Modify: `Sources/piqley/State/RuleEvaluator.swift:337-347`
- Test: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/piqleyTests/RuleEvaluatorTests.swift`:

```swift
@Test("write clone action copies field from original namespace into file metadata")
func writeCloneSingleField() async throws {
    let rule = Rule(
        match: nil,
        emit: [],
        write: [EmitConfig(
            action: "clone", field: "EXIF:FNumber",
            values: nil, replacements: nil,
            source: "original:EXIF:FNumber"
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let buffer = MetadataBuffer(preloaded: [
        "img.jpg": [:]
    ])
    _ = await evaluator.evaluate(
        state: ["original": ["EXIF:FNumber": .string("f/2.8")]],
        metadataBuffer: buffer,
        imageName: "img.jpg"
    )
    let meta = await buffer.load(image: "img.jpg")
    #expect(meta["EXIF:FNumber"] == .string("f/2.8"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter writeCloneSingleField`
Expected: FAIL. Clone is a no-op in `applyAction`, so the field stays empty.

- [ ] **Step 3: Add `applyClone` method to MetadataBuffer**

Add to `Sources/piqley/State/MetadataBuffer.swift`, after the existing `applyAction` method:

```swift
/// Merge a resolved value into a specific field for an image's metadata.
func applyClone(field: String, value: JSONValue, image: String) {
    if metadata[image] == nil {
        _ = load(image: image)
    }
    var current = metadata[image] ?? [:]
    RuleEvaluator.mergeClonedValue(value, into: &current, forKey: field)
    metadata[image] = current
    dirty.insert(image)
}
```

- [ ] **Step 4: Handle clone inline in the write action loop**

In `Sources/piqley/State/RuleEvaluator.swift`, replace the write action loop (the block updated in Task 1) with:

```swift
// Write actions second (modify file metadata via buffer)
if let buffer = metadataBuffer, let image = imageName {
    for action in rule.writeActions {
        if case let .clone(field, sourceNamespace, sourceField) = action {
            if sourceNamespace == "read" {
                let fileMetadata = await buffer.load(image: image)
                if let sourceField, let val = fileMetadata[sourceField] {
                    await buffer.applyClone(field: field, value: val, image: image)
                }
            } else if let sourceField, let val = state[sourceNamespace]?[sourceField] {
                await buffer.applyClone(field: field, value: val, image: image)
            }
            continue
        }
        let resolvedAction = await resolveTemplates(
            in: action,
            state: state,
            metadataBuffer: metadataBuffer,
            imageName: imageName,
            pluginId: pluginId
        )
        await buffer.applyAction(resolvedAction, image: image)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter writeCloneSingleField`
Expected: PASS

- [ ] **Step 6: Commit**

Message: `feat: add single-field clone support for write actions`

---

### Task 3: Wildcard Clone in Write Actions

**Files:**
- Modify: `Sources/piqley/State/MetadataBuffer.swift`
- Modify: `Sources/piqley/State/RuleEvaluator.swift`
- Test: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/piqleyTests/RuleEvaluatorTests.swift`:

```swift
@Test("write clone wildcard copies all fields from original namespace into file metadata")
func writeCloneWildcard() async throws {
    let rule = Rule(
        match: nil,
        emit: [],
        write: [EmitConfig(
            action: "clone", field: "*",
            values: nil, replacements: nil,
            source: "original"
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let buffer = MetadataBuffer(preloaded: [
        "img.jpg": [:]
    ])
    _ = await evaluator.evaluate(
        state: ["original": [
            "EXIF:FNumber": .string("f/2.8"),
            "TIFF:Make": .string("Sony")
        ]],
        metadataBuffer: buffer,
        imageName: "img.jpg"
    )
    let meta = await buffer.load(image: "img.jpg")
    #expect(meta["EXIF:FNumber"] == .string("f/2.8"))
    #expect(meta["TIFF:Make"] == .string("Sony"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter writeCloneWildcard`
Expected: FAIL. The wildcard clone path isn't handled yet.

- [ ] **Step 3: Add `applyCloneAll` method to MetadataBuffer**

Add to `Sources/piqley/State/MetadataBuffer.swift`, after `applyClone`:

```swift
/// Merge all key-value pairs from a resolved namespace into an image's metadata.
func applyCloneAll(values: [String: JSONValue], image: String) {
    if metadata[image] == nil {
        _ = load(image: image)
    }
    var current = metadata[image] ?? [:]
    for (key, val) in values {
        RuleEvaluator.mergeClonedValue(val, into: &current, forKey: key)
    }
    metadata[image] = current
    dirty.insert(image)
}
```

- [ ] **Step 4: Add wildcard branch to write clone handling**

In `Sources/piqley/State/RuleEvaluator.swift`, update the clone handling inside the write action loop. Replace the clone `if case` block from Task 2 with:

```swift
if case let .clone(field, sourceNamespace, sourceField) = action {
    if sourceNamespace == "read" {
        let fileMetadata = await buffer.load(image: image)
        if field == "*" {
            await buffer.applyCloneAll(values: fileMetadata, image: image)
        } else if let sourceField, let val = fileMetadata[sourceField] {
            await buffer.applyClone(field: field, value: val, image: image)
        }
    } else if field == "*" {
        if let namespaceData = state[sourceNamespace] {
            await buffer.applyCloneAll(values: namespaceData, image: image)
        }
    } else if let sourceField, let val = state[sourceNamespace]?[sourceField] {
        await buffer.applyClone(field: field, value: val, image: image)
    }
    continue
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter writeCloneWildcard`
Expected: PASS

- [ ] **Step 6: Commit**

Message: `feat: add wildcard clone support for write actions`

---

### Task 4: Integration Test: Wipe-and-Restore Pattern

**Files:**
- Test: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write the integration test**

This test validates the exact pattern the sanitizer plugin will use: `removeField: "*"` followed by clone-back of specific fields.

Add to `Tests/piqleyTests/RuleEvaluatorTests.swift`:

```swift
@Test("removeField wildcard then clone restores only allowed fields")
func writeWipeAndRestore() async throws {
    let rules = [
        Rule(
            match: nil,
            emit: [],
            write: [EmitConfig(
                action: "removeField", field: "*",
                values: nil, replacements: nil, source: nil
            )]
        ),
        Rule(
            match: nil,
            emit: [],
            write: [
                EmitConfig(action: "clone", field: "TIFF:Make", values: nil, replacements: nil, source: "original:TIFF:Make"),
                EmitConfig(action: "clone", field: "EXIF:FNumber", values: nil, replacements: nil, source: "original:EXIF:FNumber"),
            ]
        ),
    ]
    let evaluator = try RuleEvaluator(rules: rules, logger: logger)
    let buffer = MetadataBuffer(preloaded: [
        "img.jpg": [
            "TIFF:Make": .string("Sony"),
            "EXIF:FNumber": .string("f/2.8"),
            "EXIF:GPSLatitude": .string("40.7128"),
            "EXIF:SerialNumber": .string("12345"),
            "XMP:CreatorTool": .string("Lightroom"),
        ]
    ])
    _ = await evaluator.evaluate(
        state: ["original": [
            "TIFF:Make": .string("Sony"),
            "EXIF:FNumber": .string("f/2.8"),
            "EXIF:GPSLatitude": .string("40.7128"),
            "EXIF:SerialNumber": .string("12345"),
            "XMP:CreatorTool": .string("Lightroom"),
        ]],
        metadataBuffer: buffer,
        imageName: "img.jpg"
    )
    let meta = await buffer.load(image: "img.jpg")
    #expect(meta["TIFF:Make"] == .string("Sony"))
    #expect(meta["EXIF:FNumber"] == .string("f/2.8"))
    #expect(meta["EXIF:GPSLatitude"] == nil)
    #expect(meta["EXIF:SerialNumber"] == nil)
    #expect(meta["XMP:CreatorTool"] == nil)
    #expect(meta.count == 2)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter writeWipeAndRestore`
Expected: PASS (all prior tasks should make this work)

- [ ] **Step 3: Commit**

Message: `test: add wipe-and-restore integration test for write actions`

---

### Task 5: Run Full Test Suite

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `swift test`
Expected: All tests pass. No regressions in emit-side clone, template resolution, or other write actions.

- [ ] **Step 2: Commit if any fixups were needed**

Only if test failures required fixes.

---

### Task 6: Create Metadata Sanitizer Plugin

**Files:**
- Create: `~/.config/piqley/plugins/photo.quigs.metadata-sanitizer/manifest.json`
- Create: `~/.config/piqley/plugins/photo.quigs.metadata-sanitizer/stage-post-process.json`

- [ ] **Step 1: Create the plugin directory**

Run: `mkdir -p ~/.config/piqley/plugins/photo.quigs.metadata-sanitizer`

- [ ] **Step 2: Create manifest.json**

Write to `~/.config/piqley/plugins/photo.quigs.metadata-sanitizer/manifest.json`:

```json
{
  "identifier": "photo.quigs.metadata-sanitizer",
  "name": "Metadata Sanitizer",
  "pluginSchemaVersion": "1",
  "type": "mutable"
}
```

- [ ] **Step 3: Create stage-post-process.json**

Write to `~/.config/piqley/plugins/photo.quigs.metadata-sanitizer/stage-post-process.json`:

```json
{
  "preRules": [
    {
      "emit": [],
      "write": [
        { "action": "removeField", "field": "*" }
      ]
    },
    {
      "emit": [],
      "write": [
        { "action": "clone", "field": "TIFF:Orientation", "source": "original:TIFF:Orientation" },
        { "action": "clone", "field": "TIFF:Make", "source": "original:TIFF:Make" },
        { "action": "clone", "field": "TIFF:Model", "source": "original:TIFF:Model" },
        { "action": "clone", "field": "TIFF:Artist", "source": "original:TIFF:Artist" },
        { "action": "clone", "field": "TIFF:Copyright", "source": "original:TIFF:Copyright" },
        { "action": "clone", "field": "EXIF:DateTimeOriginal", "source": "original:EXIF:DateTimeOriginal" },
        { "action": "clone", "field": "EXIF:ExposureTime", "source": "original:EXIF:ExposureTime" },
        { "action": "clone", "field": "EXIF:FNumber", "source": "original:EXIF:FNumber" },
        { "action": "clone", "field": "EXIF:ISO", "source": "original:EXIF:ISO" },
        { "action": "clone", "field": "EXIF:FocalLength", "source": "original:EXIF:FocalLength" },
        { "action": "clone", "field": "EXIF:ColorSpace", "source": "original:EXIF:ColorSpace" },
        { "action": "clone", "field": "EXIF:PixelXDimension", "source": "original:EXIF:PixelXDimension" },
        { "action": "clone", "field": "EXIF:PixelYDimension", "source": "original:EXIF:PixelYDimension" },
        { "action": "clone", "field": "IPTC:Byline", "source": "original:IPTC:Byline" },
        { "action": "clone", "field": "IPTC:Copyright", "source": "original:IPTC:Copyright" },
        { "action": "clone", "field": "IPTC:CopyrightNotice", "source": "original:IPTC:CopyrightNotice" },
        { "action": "clone", "field": "XMP:Creator", "source": "original:XMP:Creator" },
        { "action": "clone", "field": "XMP:Rights", "source": "original:XMP:Rights" }
      ]
    }
  ]
}
```

- [ ] **Step 4: Verify plugin loads**

Run: `piqley plugin list`
Expected: `photo.quigs.metadata-sanitizer` appears in the plugin list.

- [ ] **Step 5: No commit needed**

Plugin files live in `~/.config/piqley/plugins/`, not in the git repo.
