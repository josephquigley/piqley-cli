# Multi-Platform Plugin Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable plugin packages to contain binaries and data for multiple platforms, with the CLI filtering to the host platform at install time.

**Architecture:** The build manifest's `bin` and `data` fields become objects keyed by platform triple (`macos-arm64`, `linux-amd64`, `linux-arm64`). The Packager stages files into platform subdirectories. The installer flattens the matching platform's files into the existing flat layout, so runtime behavior is unchanged.

**Tech Stack:** Swift, JSON Schema, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-22-multi-platform-plugins-design.md`

---

### Task 1: Add `supportedPlatforms` to PluginManifest (piqley-core)

**Files:**
- Modify: `piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`

- [ ] **Step 1: Add `supportedPlatforms` property to PluginManifest**

Add a new stored property and update init, CodingKeys, decoder, and encoder:

```swift
// Add stored property after conversionFormat:
public let supportedPlatforms: [String]?

// Add to CodingKeys enum:
case supportedPlatforms

// Add to init parameters (after conversionFormat):
supportedPlatforms: [String]? = nil

// Add to init body:
self.supportedPlatforms = supportedPlatforms

// Add to init(from decoder:) before supportedFormats:
supportedPlatforms = try container.decodeIfPresent([String].self, forKey: .supportedPlatforms)

// Add to encode(to:) before supportedFormats:
try container.encodeIfPresent(supportedPlatforms, forKey: .supportedPlatforms)
```

- [ ] **Step 2: Update `supportedSchemaVersions` to include "2"**

```swift
public static let supportedSchemaVersions: Set<String> = ["1", "2"]
```

- [ ] **Step 3: Build piqley-core to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Commit**

```
feat: add supportedPlatforms to PluginManifest and support schema v2
```

---

### Task 2: Add `supportedPlatforms` to manifest.schema.json (piqley-plugin-sdk)

**Files:**
- Modify: `piqley-plugin-sdk/schemas/manifest.schema.json`

- [ ] **Step 1: Update pluginSchemaVersion const and add supportedPlatforms**

Change `pluginSchemaVersion` from `"const": "1"` to allow both versions:

```json
"pluginSchemaVersion": { "type": "string", "enum": ["1", "2"] }
```

Add `supportedPlatforms` to the `properties` object:

```json
"supportedPlatforms": {
  "type": "array",
  "items": {
    "type": "string",
    "enum": ["macos-arm64", "linux-amd64", "linux-arm64"]
  },
  "minItems": 1
}
```

- [ ] **Step 2: Commit**

```
feat: add supportedPlatforms to manifest schema, allow schema v2
```

---

### Task 3: Update BuildManifest to platform-keyed bin/data (piqley-plugin-sdk)

**Files:**
- Modify: `piqley-plugin-sdk/swift/PiqleyPluginSDK/BuildManifest.swift`

- [ ] **Step 1: Write failing test for platform-keyed BuildManifest decoding**

Add to `piqley-plugin-sdk/swift/Tests/PackagerTests.swift`:

```swift
@Test func decodesPlatformKeyedBuildManifest() throws {
    let json = """
    {
        "identifier": "com.test.multi-arch",
        "pluginName": "multi-arch",
        "pluginSchemaVersion": "2",
        "bin": {
            "macos-arm64": [".build/release/multi-arch"],
            "linux-amd64": ["dist/multi-arch"]
        },
        "data": {
            "macos-arm64": ["models/mac.bin"],
            "linux-amd64": ["models/linux.bin"]
        }
    }
    """
    let data = Data(json.utf8)
    let manifest = try JSONDecoder().decode(BuildManifest.self, from: data)

    #expect(manifest.identifier == "com.test.multi-arch")
    #expect(manifest.pluginSchemaVersion == "2")
    #expect(manifest.bin == [
        "macos-arm64": [".build/release/multi-arch"],
        "linux-amd64": ["dist/multi-arch"]
    ])
    #expect(manifest.data == [
        "macos-arm64": ["models/mac.bin"],
        "linux-amd64": ["models/linux.bin"]
    ])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter decodesPlatformKeyedBuildManifest 2>&1 | tail -10`
Expected: Compilation error (bin type mismatch)

- [ ] **Step 3: Update BuildManifest struct**

Change the `bin` and `data` types and update the decoder:

```swift
// Change stored properties:
public let bin: [String: [String]]
public let data: [String: [String]]

// Update init parameters:
bin: [String: [String]],
data: [String: [String]] = [:],

// Update init(from decoder:):
self.bin = try container.decode([String: [String]].self, forKey: .bin)
self.data = try container.decodeIfPresent([String: [String]].self, forKey: .data) ?? [:]
```

- [ ] **Step 4: Add data-keys-subset-of-bin-keys validation in init(from:)**

After decoding `bin` and `data`, validate that data's platform keys are a subset of bin's:

```swift
// After decoding bin and data:
let invalidDataPlatforms = Set(self.data.keys).subtracting(Set(self.bin.keys))
if !invalidDataPlatforms.isEmpty {
    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: [CodingKeys.data],
            debugDescription: "Data platforms \(invalidDataPlatforms.sorted()) are not declared in bin"
        )
    )
}
```

- [ ] **Step 5: Update `toPluginManifest()` to pass supportedPlatforms**

```swift
public func toPluginManifest() throws -> PluginManifest {
    let semver: SemanticVersion? = try pluginVersion.map { try SemanticVersion($0) }
    return PluginManifest(
        identifier: identifier,
        name: pluginName,
        description: description,
        pluginSchemaVersion: pluginSchemaVersion,
        pluginVersion: semver,
        config: config ?? [],
        setup: setup,
        dependencies: dependencies,
        supportedFormats: supportedFormats,
        conversionFormat: conversionFormat,
        supportedPlatforms: Array(bin.keys).sorted()
    )
}
```

- [ ] **Step 6: Update existing tests that use the old flat bin/data format**

In `PackagerTests.swift`, update `decodesBuildManifest`:

```swift
@Test func decodesBuildManifest() throws {
    let json = """
    {
        "identifier": "com.test.my-plugin",
        "pluginName": "my-plugin",
        "pluginSchemaVersion": "2",
        "bin": {
            "macos-arm64": ["build/my-plugin"]
        },
        "data": {
            "macos-arm64": ["templates/default.json"]
        }
    }
    """
    let data = Data(json.utf8)
    let manifest = try JSONDecoder().decode(BuildManifest.self, from: data)

    #expect(manifest.identifier == "com.test.my-plugin")
    #expect(manifest.pluginName == "my-plugin")
    #expect(manifest.pluginSchemaVersion == "2")
    #expect(manifest.bin == ["macos-arm64": ["build/my-plugin"]])
    #expect(manifest.data == ["macos-arm64": ["templates/default.json"]])
    #expect(manifest.dependencies?.isEmpty ?? true)
}
```

Update `decodesBuildManifestWithoutIdentifierThrows` to use the new format:

```swift
@Test func decodesBuildManifestWithoutIdentifierThrows() {
    let json = """
    {
        "pluginName": "my-plugin",
        "pluginSchemaVersion": "2",
        "bin": { "macos-arm64": ["build/my-plugin"] },
        "data": {}
    }
    """
    let data = Data(json.utf8)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(BuildManifest.self, from: data)
    }
}
```

Update `makePluginDirectory` helper to use the new format:

```swift
private func makePluginDirectory(
    pluginName: String = "test-plugin",
    identifier: String? = nil,
    includeBin: Bool = true,
    includeConfig: Bool = false
) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    let binValue: [String: Any] = includeBin
        ? ["macos-arm64": ["my-binary"]]
        : ["macos-arm64": ["missing-binary"]]

    let buildManifestDict: [String: Any] = [
        "identifier": identifier ?? "com.test.\(pluginName)",
        "pluginName": pluginName,
        "pluginSchemaVersion": "2",
        "bin": binValue,
        "data": [:] as [String: Any],
        "dependencies": [] as [Any],
    ]
    let buildManifestData = try JSONSerialization.data(withJSONObject: buildManifestDict)
    try buildManifestData.write(to: dir.appendingPathComponent("piqley-build-manifest.json"))

    if includeConfig {
        let configData = Data("{}".utf8)
        try configData.write(to: dir.appendingPathComponent("config.json"))
    }

    if includeBin {
        let binData = Data("#!/bin/sh\necho hello".utf8)
        try binData.write(to: dir.appendingPathComponent("my-binary"))
    }

    return dir
}
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -15`
Expected: All tests pass (schema conformance tests may fail; those are Task 4)

- [ ] **Step 8: Commit**

```
feat: change BuildManifest bin/data to platform-keyed dictionaries
```

---

### Task 4: Update build-manifest.schema.json (piqley-plugin-sdk)

**Files:**
- Modify: `piqley-plugin-sdk/schemas/build-manifest.schema.json`

- [ ] **Step 1: Update the schema**

Replace the `bin` and `data` properties and update `pluginSchemaVersion`:

```json
"pluginSchemaVersion": { "type": "string", "const": "2" },
```

```json
"bin": {
  "type": "object",
  "minProperties": 1,
  "patternProperties": {
    "^(macos-arm64|linux-amd64|linux-arm64)$": {
      "type": "array",
      "items": { "type": "string" },
      "minItems": 1
    }
  },
  "additionalProperties": false
},
"data": {
  "type": "object",
  "patternProperties": {
    "^(macos-arm64|linux-amd64|linux-arm64)$": {
      "type": "array",
      "items": { "type": "string" }
    }
  },
  "additionalProperties": false
}
```

- [ ] **Step 2: Update SchemaConformanceTests for new build manifest format**

In `SchemaConformanceTests.swift`, update `validBuildManifestConformsToSchema`:

```swift
@Test func validBuildManifestConformsToSchema() throws {
    let json: [String: Any] = [
        "pluginName": "my-plugin",
        "pluginSchemaVersion": "2",
        "bin": [
            "macos-arm64": ["my-plugin"]
        ] as [String: Any],
        "data": [
            "macos-arm64": ["resources/template.txt"]
        ] as [String: Any],
        "dependencies": [
            [
                "url": "https://github.com/example/dep.piqleyplugin",
                "version": [
                    "from": "1.0.0",
                    "rule": "upToNextMajor"
                ]
            ] as [String: Any]
        ]
    ]

    let result = try validate(json, against: "build-manifest.schema.json")
    #expect(result.valid, "Build manifest should conform to schema: \(result.errors)")
}
```

- [ ] **Step 3: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 4: Commit**

```
feat: update build-manifest schema to platform-keyed bin/data
```

---

### Task 5: Update Packager for platform subdirectories (piqley-plugin-sdk)

**Files:**
- Modify: `piqley-plugin-sdk/swift/PiqleyPluginSDK/Packager.swift`
- Modify: `piqley-plugin-sdk/swift/Tests/PackagerTests.swift`

- [ ] **Step 1: Write failing test for platform-keyed packaging**

Add to `PackagerTests.swift`:

```swift
@Test func packagerCreatesPerPlatformBinDirectories() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // Create build manifest with two platforms
    let buildManifestDict: [String: Any] = [
        "identifier": "com.test.multi",
        "pluginName": "multi",
        "pluginSchemaVersion": "2",
        "bin": [
            "macos-arm64": ["bin-mac"],
            "linux-amd64": ["bin-linux"],
        ] as [String: Any],
        "data": [
            "macos-arm64": ["data-mac.txt"],
        ] as [String: Any],
    ]
    let buildManifestData = try JSONSerialization.data(withJSONObject: buildManifestDict)
    try buildManifestData.write(to: dir.appendingPathComponent("piqley-build-manifest.json"))

    // Create the binary and data files
    try Data("mac-binary".utf8).write(to: dir.appendingPathComponent("bin-mac"))
    try Data("linux-binary".utf8).write(to: dir.appendingPathComponent("bin-linux"))
    try Data("mac-data".utf8).write(to: dir.appendingPathComponent("data-mac.txt"))

    let output = try Packager.package(directory: dir)
    defer { try? fm.removeItem(at: output) }

    // Unzip and verify structure
    let unzipDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: unzipDir) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", output.path, "-d", unzipDir.path]
    try process.run()
    process.waitUntilExit()

    let pluginRoot = unzipDir.appendingPathComponent("multi")

    // Verify platform subdirectories exist under bin/
    #expect(fm.fileExists(atPath: pluginRoot.appendingPathComponent("bin/macos-arm64/bin-mac").path))
    #expect(fm.fileExists(atPath: pluginRoot.appendingPathComponent("bin/linux-amd64/bin-linux").path))

    // Verify platform subdirectories exist under data/
    #expect(fm.fileExists(atPath: pluginRoot.appendingPathComponent("data/macos-arm64/data-mac.txt").path))

    // Verify manifest.json has supportedPlatforms
    let manifestData = try Data(contentsOf: pluginRoot.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
    #expect(manifest.supportedPlatforms?.sorted() == ["linux-amd64", "macos-arm64"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter packagerCreatesPerPlatformBinDirectories 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Update Packager.package() for platform-keyed layout**

Replace the bin/data verification and staging sections in `Packager.swift`:

```swift
// 3. Verify all bin paths exist
for (_, paths) in buildManifest.bin {
    for bin in paths {
        let binURL = directory.appendingPathComponent(bin)
        guard fm.fileExists(atPath: binURL.path) else {
            throw PackagerError.missingPath(bin)
        }
    }
}

// 4. Verify all data paths exist
for (_, paths) in buildManifest.data {
    for dataPath in paths {
        let dataURL = directory.appendingPathComponent(dataPath)
        guard fm.fileExists(atPath: dataURL.path) else {
            throw PackagerError.missingPath(dataPath)
        }
    }
}
```

Replace the bin/data copy sections:

```swift
// Copy bin files into platform subdirectories
if !buildManifest.bin.isEmpty {
    let binDir = pluginDir.appendingPathComponent("bin")
    for (platform, paths) in buildManifest.bin {
        let platformDir = binDir.appendingPathComponent(platform)
        try fm.createDirectory(at: platformDir, withIntermediateDirectories: true)
        for bin in paths {
            let src = directory.appendingPathComponent(bin)
            let dst = platformDir.appendingPathComponent(URL(fileURLWithPath: bin).lastPathComponent)
            try fm.copyItem(at: src, to: dst)
        }
    }
}

// Copy data files into platform subdirectories
if !buildManifest.data.isEmpty {
    let dataDir = pluginDir.appendingPathComponent("data")
    for (platform, paths) in buildManifest.data {
        let platformDir = dataDir.appendingPathComponent(platform)
        try fm.createDirectory(at: platformDir, withIntermediateDirectories: true)
        for dataPath in paths {
            let src = directory.appendingPathComponent(dataPath)
            let dst = platformDir.appendingPathComponent(URL(fileURLWithPath: dataPath).lastPathComponent)
            try fm.copyItem(at: src, to: dst)
        }
    }
}
```

- [ ] **Step 4: Update existing Packager tests for new format**

The `makePluginDirectory` helper was already updated in Task 3. Verify the existing tests `packagerProducesZip`, `packagerGeneratesManifestJson`, `packagerGeneratesEmptyConfigWhenMissing`, and `packagerFailsOnMissingBinPath` still pass with the new format. The `packagerGeneratesManifestJson` test should also verify `supportedPlatforms`:

Add after the existing assertions in `packagerGeneratesManifestJson`:

```swift
#expect(manifest.supportedPlatforms == ["macos-arm64"])
```

- [ ] **Step 5: Run all tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 6: Commit**

```
feat: package bin/data into platform subdirectories
```

---

### Task 6: Add HostPlatform and update InstallCommand (piqley-cli)

**Files:**
- Create: `piqley-cli/Sources/piqley/Constants/HostPlatform.swift`
- Modify: `piqley-cli/Sources/piqley/CLI/InstallCommand.swift`

- [ ] **Step 1: Create HostPlatform**

Create `piqley-cli/Sources/piqley/Constants/HostPlatform.swift`:

```swift
enum HostPlatform {
    static var current: String {
        #if os(macOS) && arch(arm64)
        return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-amd64"
        #elseif os(Linux) && arch(arm64)
        return "linux-arm64"
        #else
        fatalError("Unsupported platform")
        #endif
    }
}
```

- [ ] **Step 2: Add `unsupportedPlatform` error case to InstallError**

```swift
case unsupportedPlatform(host: String, supported: [String])
```

Add to the `description` switch:

```swift
case .unsupportedPlatform(let host, let supported):
    "This plugin does not support \(host). Supported platforms: \(supported.joined(separator: ", "))"
```

- [ ] **Step 3: Add platform check after schema version validation**

Insert after step 4 (validate schema version) in `PluginInstaller.install`:

```swift
// 5. Check platform support
if let supportedPlatforms = manifest.supportedPlatforms {
    guard supportedPlatforms.contains(HostPlatform.current) else {
        throw InstallError.unsupportedPlatform(
            host: HostPlatform.current,
            supported: supportedPlatforms
        )
    }
}
```

- [ ] **Step 4: Add platform flattening BEFORE moving plugin to install location**

Insert after the platform check (step 5) and before the "Check if already installed" step (step 6). This flattens in the temp directory so the install location only ever receives a clean, flat layout:

```swift
// 6. Flatten platform-specific bin/ and data/ directories in temp
let tempBinDir = pluginDir.appendingPathComponent(PluginDirectory.bin)
if fileManager.fileExists(atPath: tempBinDir.path) {
    let platformBinDir = tempBinDir.appendingPathComponent(HostPlatform.current)
    if fileManager.fileExists(atPath: platformBinDir.path) {
        // Move platform files up to bin/
        let platformFiles = try fileManager.contentsOfDirectory(
            at: platformBinDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in platformFiles {
            let dst = tempBinDir.appendingPathComponent(file.lastPathComponent)
            try fileManager.moveItem(at: file, to: dst)
        }
        // Remove all platform subdirectories
        let binContents = try fileManager.contentsOfDirectory(
            at: tempBinDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in binContents {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fileManager.removeItem(at: item)
            }
        }
    }
}

let tempDataDir = pluginDir.appendingPathComponent(PluginDirectory.data)
if fileManager.fileExists(atPath: tempDataDir.path) {
    let platformDataDir = tempDataDir.appendingPathComponent(HostPlatform.current)
    if fileManager.fileExists(atPath: platformDataDir.path) {
        let platformFiles = try fileManager.contentsOfDirectory(
            at: platformDataDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in platformFiles {
            let dst = tempDataDir.appendingPathComponent(file.lastPathComponent)
            try fileManager.moveItem(at: file, to: dst)
        }
        let dataContents = try fileManager.contentsOfDirectory(
            at: tempDataDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in dataContents {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fileManager.removeItem(at: item)
            }
        }
    }
}
```

The remaining steps (check if already installed, move to install location, chmod, create logs/data dirs) stay in their current order with renumbered comments.

- [ ] **Step 5: Build piqley-cli to verify compilation**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 6: Commit**

```
feat: add platform filtering to plugin installer
```

---

### Task 6b: Add install-time tests for platform filtering (piqley-cli)

**Files:**
- Modify: `piqley-cli/Tests/piqleyTests/InstallCommandTests.swift` (or create if it doesn't exist)

- [ ] **Step 1: Write test for rejecting unsupported platform**

```swift
@Test func installRejectsUnsupportedPlatform() throws {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let pluginsDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: tempDir)
        try? fm.removeItem(at: pluginsDir)
    }

    // Create a plugin zip that only supports a different platform
    let pluginDir = tempDir.appendingPathComponent("test-plugin")
    try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
        "identifier": "com.test.unsupported",
        "name": "unsupported",
        "pluginSchemaVersion": "2",
        "supportedPlatforms": ["linux-amd64"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest)
    try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))

    // Create a minimal stage file
    try Data("{}".utf8).write(to: pluginDir.appendingPathComponent("stage-process.json"))

    // Zip it
    let zipURL = tempDir.appendingPathComponent("unsupported.piqleyplugin")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-r", "-q", zipURL.path, "test-plugin"]
    process.currentDirectoryURL = tempDir
    try process.run()
    process.waitUntilExit()

    #expect(throws: InstallError.self) {
        try PluginInstaller.install(from: zipURL, to: pluginsDir)
    }
}
```

- [ ] **Step 2: Write test for successful platform flattening**

```swift
@Test func installFlattensPlatformDirectories() throws {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let pluginsDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: tempDir)
        try? fm.removeItem(at: pluginsDir)
    }

    // Create a plugin zip with platform subdirectories
    let pluginDir = tempDir.appendingPathComponent("test-plugin")
    try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
        "identifier": "com.test.multi",
        "name": "multi",
        "pluginSchemaVersion": "2",
        "supportedPlatforms": [HostPlatform.current, "linux-amd64"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest)
    try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))
    try Data("{}".utf8).write(to: pluginDir.appendingPathComponent("stage-process.json"))

    // Create platform bin directories
    let hostBinDir = pluginDir.appendingPathComponent("bin/\(HostPlatform.current)")
    let otherBinDir = pluginDir.appendingPathComponent("bin/linux-amd64")
    try fm.createDirectory(at: hostBinDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: otherBinDir, withIntermediateDirectories: true)
    try Data("host-binary".utf8).write(to: hostBinDir.appendingPathComponent("my-plugin"))
    try Data("other-binary".utf8).write(to: otherBinDir.appendingPathComponent("my-plugin"))

    // Zip it
    let zipURL = tempDir.appendingPathComponent("multi.piqleyplugin")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-r", "-q", zipURL.path, "test-plugin"]
    process.currentDirectoryURL = tempDir
    try process.run()
    process.waitUntilExit()

    try PluginInstaller.install(from: zipURL, to: pluginsDir)

    let installDir = pluginsDir.appendingPathComponent("com.test.multi")
    // Binary should be flat in bin/, not in a platform subdirectory
    #expect(fm.fileExists(atPath: installDir.appendingPathComponent("bin/my-plugin").path))
    #expect(!fm.fileExists(atPath: installDir.appendingPathComponent("bin/\(HostPlatform.current)").path))
    #expect(!fm.fileExists(atPath: installDir.appendingPathComponent("bin/linux-amd64").path))
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter install 2>&1 | tail -15`
Expected: All install tests pass

- [ ] **Step 4: Commit**

```
test: add install-time platform filtering tests
```

---

### Task 7: Update template build manifests (piqley-plugin-sdk)

**Files:**
- Modify: `piqley-plugin-sdk/templates/swift/piqley-build-manifest.json`
- Modify: `piqley-plugin-sdk/templates/go/piqley-build-manifest.json`
- Modify: `piqley-plugin-sdk/templates/node/piqley-build-manifest.json`
- Modify: `piqley-plugin-sdk/templates/python/piqley-build-manifest.json`

- [ ] **Step 1: Update Swift template**

```json
{
  "identifier": "__PLUGIN_IDENTIFIER__",
  "pluginName": "__PLUGIN_NAME__",
  "pluginSchemaVersion": "2",
  "pluginVersion": "0.1.0",
  "bin": {
    "macos-arm64": [".build/release/__PLUGIN_PACKAGE_NAME__"]
  },
  "data": {},
  "dependencies": []
}
```

- [ ] **Step 2: Update Go template**

```json
{
  "identifier": "__PLUGIN_IDENTIFIER__",
  "pluginName": "__PLUGIN_NAME__",
  "pluginSchemaVersion": "2",
  "pluginVersion": "0.1.0",
  "bin": {
    "macos-arm64": ["__PLUGIN_IDENTIFIER__"]
  },
  "data": {},
  "dependencies": []
}
```

- [ ] **Step 3: Update Node template**

```json
{
  "identifier": "__PLUGIN_IDENTIFIER__",
  "pluginName": "__PLUGIN_NAME__",
  "pluginSchemaVersion": "2",
  "pluginVersion": "0.1.0",
  "bin": {
    "macos-arm64": ["dist/index.js"]
  },
  "data": {},
  "dependencies": []
}
```

- [ ] **Step 4: Update Python template**

```json
{
  "identifier": "__PLUGIN_IDENTIFIER__",
  "pluginName": "__PLUGIN_NAME__",
  "pluginSchemaVersion": "2",
  "pluginVersion": "0.1.0",
  "bin": {
    "macos-arm64": ["src/__PLUGIN_IDENTIFIER__/main.py"]
  },
  "data": {},
  "dependencies": []
}
```

- [ ] **Step 5: Commit**

```
feat: update plugin templates to schema v2 with platform-keyed bin
```

---

### Task 8: End-to-end verification

- [ ] **Step 1: Run piqley-plugin-sdk full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 2: Run piqley-core full test suite**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Build piqley-cli**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift build 2>&1 | tail -10`
Expected: Build succeeded
