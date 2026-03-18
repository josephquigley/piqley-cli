# Linux Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make piqley build and run on both macOS and Linux.

**Architecture:** Platform-specific implementations behind existing protocols. `#if os()` at construction/factory points only. New `FileSecretStore` for Linux; `MetadataExtractor` stubbed on Linux. Keychain code conditionally compiled on macOS only.

**Tech Stack:** Swift 6.2, Foundation, swift-corelibs-foundation (Linux)

**Spec:** `docs/superpowers/specs/2026-03-18-linux-support-design.md`

---

### Task 1: Package.swift — Remove macOS Platform Restriction

**Files:**
- Modify: `Package.swift:6`

- [ ] **Step 1: Remove platforms line**

In `Package.swift`, remove line 6:
```swift
    platforms: [.macOS(.v13)],
```

The file should read:
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "piqley",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "piqley",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "piqleyTests",
            dependencies: ["piqley"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Build to verify no regressions**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (on macOS).

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: remove macOS platform restriction from Package.swift"
```

---

### Task 2: SecretStore Error Enum — Replace OSStatus with Int32

**Files:**
- Modify: `Sources/piqley/Secrets/SecretStore.swift:28-52`
- Modify: `Sources/piqley/Secrets/KeychainSecretStore.swift` (cast OSStatus to Int32)

- [ ] **Step 1: Update SecretStoreError to use Int32 and platform-conditional strings**

In `Sources/piqley/Secrets/SecretStore.swift`, replace the `SecretStoreError` enum (lines 28-52) with:

```swift
enum SecretStoreError: Error, LocalizedError {
    case notFound(key: String)
    case unexpectedError(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .notFound(key):
            #if os(macOS)
            "Keychain secret not found for key: \(key)"
            #else
            "Secret not found for key: \(key)"
            #endif
        case let .unexpectedError(status):
            #if os(macOS)
            "Keychain error: \(status)"
            #else
            "Secret store error: \(status)"
            #endif
        }
    }

    var failureReason: String? {
        switch self {
        case .notFound:
            #if os(macOS)
            "No matching entry exists in the macOS Keychain."
            #else
            "No matching entry exists in the secrets file."
            #endif
        case .unexpectedError:
            #if os(macOS)
            "The Keychain returned an unexpected status code."
            #else
            "The secret store encountered an unexpected error."
            #endif
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound:
            "Run 'piqley secret set <plugin> <key>' to store the credential."
        case .unexpectedError:
            #if os(macOS)
            "Check Keychain Access.app for permission issues."
            #else
            "Check that ~/.config/piqley/secrets.json is readable."
            #endif
        }
    }
}
```

- [ ] **Step 2: Update KeychainSecretStore to cast OSStatus to Int32**

In `Sources/piqley/Secrets/KeychainSecretStore.swift`, change the two `throw SecretStoreError.unexpectedError(status:)` calls to cast:

Line 27: `throw SecretStoreError.unexpectedError(status: Int32(status))`
Line 43: `throw SecretStoreError.unexpectedError(status: Int32(status))`
Line 54 (in delete): `throw SecretStoreError.unexpectedError(status: Int32(status))`

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Run existing tests**

Run: `swift test --filter SecretStore 2>&1 | tail -10`
Expected: All existing tests pass (no behavior change on macOS).

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Secrets/SecretStore.swift Sources/piqley/Secrets/KeychainSecretStore.swift
git commit -m "refactor: replace OSStatus with Int32 in SecretStoreError for cross-platform compatibility"
```

---

### Task 3: FileSecretStore — New Linux Secret Store

**Files:**
- Create: `Sources/piqley/Secrets/FileSecretStore.swift`

- [ ] **Step 1: Create FileSecretStore**

Create `Sources/piqley/Secrets/FileSecretStore.swift`:

```swift
#if !os(macOS)
import Foundation

struct FileSecretStore: SecretStore {
    private let fileURL: URL

    init() {
        self.fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/secrets.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func get(key: String) throws -> String {
        let secrets = try loadSecrets()
        guard let value = secrets[key] else {
            throw SecretStoreError.notFound(key: key)
        }
        return value
    }

    func set(key: String, value: String) throws {
        var secrets = (try? loadSecrets()) ?? [:]
        secrets[key] = value
        try saveSecrets(secrets)
    }

    func delete(key: String) throws {
        var secrets = (try? loadSecrets()) ?? [:]
        secrets.removeValue(forKey: key)
        try saveSecrets(secrets)
    }

    private func loadSecrets() throws -> [String: String] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func saveSecrets(_ secrets: [String: String]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(secrets)
        try data.write(to: fileURL, options: .atomic)
        // Set file permissions to 0600 (owner read/write only)
        chmod(fileURL.path, 0o600)
    }
}
#endif
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (file is `#if !os(macOS)` so it's excluded on macOS, but should have no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/Secrets/FileSecretStore.swift
git commit -m "feat: add FileSecretStore for Linux secret storage"
```

---

### Task 4: KeychainSecretStore — Wrap in Platform Conditional

**Files:**
- Modify: `Sources/piqley/Secrets/KeychainSecretStore.swift`

- [ ] **Step 1: Wrap entire file in #if os(macOS)**

Add `#if os(macOS)` before `import Foundation` (line 1) and `#endif` after the closing brace of the struct (after line 58):

```swift
#if os(macOS)
import Foundation
import Security

struct KeychainSecretStore: SecretStore {
    // ... existing code unchanged ...
}
#endif
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/Secrets/KeychainSecretStore.swift
git commit -m "build: wrap KeychainSecretStore in #if os(macOS) conditional"
```

---

### Task 5: Factory Function and Replace Construction Sites

**Files:**
- Modify: `Sources/piqley/Secrets/SecretStore.swift` (add factory function)
- Modify: `Sources/piqley/CLI/ProcessCommand.swift:43`
- Modify: `Sources/piqley/CLI/SetupCommand.swift:57`
- Modify: `Sources/piqley/CLI/SecretCommand.swift:28,47`
- Modify: `Sources/piqley/CLI/PluginCommand.swift:36`

- [ ] **Step 1: Add factory function to SecretStore.swift**

Add at the bottom of `Sources/piqley/Secrets/SecretStore.swift` (before the closing of the file):

```swift
func makeDefaultSecretStore() -> any SecretStore {
    #if os(macOS)
    KeychainSecretStore()
    #else
    FileSecretStore()
    #endif
}
```

- [ ] **Step 2: Replace KeychainSecretStore() in ProcessCommand.swift**

Line 43: Change `let secretStore = KeychainSecretStore()` to `let secretStore = makeDefaultSecretStore()`

- [ ] **Step 3: Replace KeychainSecretStore() in SetupCommand.swift**

Line 57: Change `let secretStore = KeychainSecretStore()` to `let secretStore = makeDefaultSecretStore()`

- [ ] **Step 4: Replace KeychainSecretStore() in SecretCommand.swift**

Line 28: Change `let store = KeychainSecretStore()` to `let store = makeDefaultSecretStore()`
Line 47: Change `let store = KeychainSecretStore()` to `let store = makeDefaultSecretStore()`

- [ ] **Step 5: Replace KeychainSecretStore() in PluginCommand.swift**

Line 36: Change `let secretStore = KeychainSecretStore()` to `let secretStore = makeDefaultSecretStore()`

- [ ] **Step 6: Build and run tests**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: Build succeeds, all tests pass. Behavior unchanged on macOS.

- [ ] **Step 7: Commit**

```bash
git add Sources/piqley/Secrets/SecretStore.swift Sources/piqley/CLI/ProcessCommand.swift Sources/piqley/CLI/SetupCommand.swift Sources/piqley/CLI/SecretCommand.swift Sources/piqley/CLI/PluginCommand.swift
git commit -m "refactor: replace KeychainSecretStore() with makeDefaultSecretStore() factory"
```

---

### Task 6: SecretCommand — Platform-Conditional Help Text

**Files:**
- Modify: `Sources/piqley/CLI/SecretCommand.swift:5-8,12-14,36-37`

- [ ] **Step 1: Update command abstracts**

Replace the `SecretCommand` configuration (line 5-8):
```swift
    static let configuration = CommandConfiguration(
        commandName: "secret",
        #if os(macOS)
        abstract: "Manage plugin secrets in the macOS Keychain"
        #else
        abstract: "Manage plugin secrets in ~/.config/piqley/secrets.json"
        #endif
        ,
        subcommands: [SetCommand.self, DeleteCommand.self]
    )
```

Replace `SetCommand` configuration (lines 12-14):
```swift
        static let configuration = CommandConfiguration(
            commandName: "set",
            #if os(macOS)
            abstract: "Store a plugin secret in the Keychain (prompts for value)"
            #else
            abstract: "Store a plugin secret (prompts for value)"
            #endif
        )
```

Replace `DeleteCommand` configuration (lines 35-37):
```swift
        static let configuration = CommandConfiguration(
            commandName: "delete",
            #if os(macOS)
            abstract: "Remove a plugin secret from the Keychain"
            #else
            abstract: "Remove a plugin secret"
            #endif
        )
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/CLI/SecretCommand.swift
git commit -m "feat: platform-conditional help text for secret command"
```

---

### Task 7: PipelineOrchestrator — Generic Secret Store References

**Files:**
- Modify: `Sources/piqley/Pipeline/PipelineOrchestrator.swift:100,195-197,206`

- [ ] **Step 1: Update comment and log messages**

Line 100: Change comment from `// Fetch secrets from Keychain — missing secret is a critical failure` to `// Fetch secrets — missing secret is a critical failure`

Line 195: Change doc comment from `/// Fetches all declared secrets for a plugin from the Keychain.` to `/// Fetches all declared secrets for a plugin from the secret store.`

Line 206: Change log message from `"[\(plugin.name)] required secret '\(key)' not found in Keychain: \(error)"` to `"[\(plugin.name)] required secret '\(key)' not found: \(error)"`

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/Pipeline/PipelineOrchestrator.swift
git commit -m "docs: replace Keychain references with generic secret store in PipelineOrchestrator"
```

---

### Task 8: ProcessLock — Replace NSString Bridge

**Files:**
- Modify: `Sources/piqley/ProcessLock.swift:9`

- [ ] **Step 1: Replace NSString path manipulation**

Line 9: Change:
```swift
        let dir = (path as NSString).deletingLastPathComponent
```
to:
```swift
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
```

- [ ] **Step 2: Run ProcessLock tests**

Run: `swift test --filter ProcessLock 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/ProcessLock.swift
git commit -m "refactor: replace NSString bridge with URL API in ProcessLock"
```

---

### Task 9: TempFolder — Replace NSTemporaryDirectory

**Files:**
- Modify: `Sources/piqley/Pipeline/TempFolder.swift:9`

- [ ] **Step 1: Replace NSTemporaryDirectory()**

Line 9: Change:
```swift
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
```
to:
```swift
        let url = FileManager.default.temporaryDirectory
```

- [ ] **Step 2: Run TempFolder tests**

Run: `swift test --filter TempFolder 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/Pipeline/TempFolder.swift
git commit -m "refactor: replace NSTemporaryDirectory with FileManager.default.temporaryDirectory"
```

---

### Task 10: MetadataExtractor — Platform Conditional with Linux Stub

**Files:**
- Modify: `Sources/piqley/State/MetadataExtractor.swift`

- [ ] **Step 1: Wrap existing code and add Linux stub**

Replace the entire file with:

```swift
#if canImport(ImageIO)
@preconcurrency import Foundation
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
#else
import Foundation

enum MetadataExtractor {
    /// Metadata extraction is not available on this platform (requires ImageIO).
    /// Returns an empty dictionary.
    static func extract(from url: URL) -> [String: JSONValue] {
        [:]
    }
}
#endif
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Run MetadataExtractor tests**

Run: `swift test --filter MetadataExtractor 2>&1 | tail -10`
Expected: All tests pass on macOS.

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/State/MetadataExtractor.swift
git commit -m "feat: add Linux stub for MetadataExtractor (ImageIO unavailable)"
```

---

### Task 11: Test Helpers — Platform Conditional with Static Fixture

**Files:**
- Modify: `Tests/piqleyTests/TestHelpers.swift`
- Create: `Tests/piqleyTests/Fixtures/test.jpg` (static minimal JPEG)

- [ ] **Step 1: Create a minimal static JPEG fixture**

Generate a minimal valid JPEG and save it to `Tests/piqleyTests/Fixtures/test.jpg`. This can be done by running a small Swift snippet on macOS that creates a tiny JPEG:

```bash
swift -e '
import Foundation
import CoreGraphics
import ImageIO

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: "Tests/piqleyTests/Fixtures/test.jpg") as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("Created test.jpg")
'
```

- [ ] **Step 2: Wrap TestHelpers.swift in platform conditional**

Replace the entire file with:

```swift
import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO

enum TestFixtures {
    static func createTestJPEG(
        at path: String,
        width: Int = 3000,
        height: Int = 2000,
        title: String? = nil,
        description: String? = nil,
        keywords: [String]? = nil,
        dateTimeOriginal: String? = "2026:01:15 10:30:00",
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        gps: Bool = false
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw TestFixtureError.cannotCreateContext }

        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else { throw TestFixtureError.cannotCreateImage }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) else {
            throw TestFixtureError.cannotCreateDestination
        }

        var properties: [String: Any] = [:]
        var exifDict: [String: Any] = [:]
        var iptcDict: [String: Any] = [:]
        var tiffDict: [String: Any] = [:]

        if let dateTimeOriginal { exifDict[kCGImagePropertyExifDateTimeOriginal as String] = dateTimeOriginal }
        if let lensModel { exifDict[kCGImagePropertyExifLensModel as String] = lensModel }
        if let title { iptcDict[kCGImagePropertyIPTCObjectName as String] = title }
        if let description { iptcDict[kCGImagePropertyIPTCCaptionAbstract as String] = description }
        if let keywords { iptcDict[kCGImagePropertyIPTCKeywords as String] = keywords }
        if let cameraMake { tiffDict["Make"] = cameraMake }
        if let cameraModel { tiffDict["Model"] = cameraModel }

        if !exifDict.isEmpty { properties[kCGImagePropertyExifDictionary as String] = exifDict }
        if !iptcDict.isEmpty { properties[kCGImagePropertyIPTCDictionary as String] = iptcDict }
        if !tiffDict.isEmpty { properties[kCGImagePropertyTIFFDictionary as String] = tiffDict }
        if gps {
            properties[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: 40.7128,
                kCGImagePropertyGPSLongitude as String: -74.0060,
            ]
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestFixtureError.cannotFinalize }
    }
}
#else
enum TestFixtures {
    /// On Linux, copy the static test fixture JPEG to the target path.
    static func createTestJPEG(
        at path: String,
        width: Int = 3000,
        height: Int = 2000,
        title: String? = nil,
        description: String? = nil,
        keywords: [String]? = nil,
        dateTimeOriginal: String? = "2026:01:15 10:30:00",
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        gps: Bool = false
    ) throws {
        guard let fixtureURL = Bundle.module.url(forResource: "test", withExtension: "jpg", subdirectory: "Fixtures") else {
            throw TestFixtureError.cannotCreateImage
        }
        try FileManager.default.copyItem(at: fixtureURL, to: URL(fileURLWithPath: path))
    }
}
#endif

enum TestFixtureError: Error, LocalizedError {
    case cannotCreateContext
    case cannotCreateImage
    case cannotCreateDestination
    case cannotFinalize

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext: "Test fixture: cannot create graphics context"
        case .cannotCreateImage: "Test fixture: cannot create test image"
        case .cannotCreateDestination: "Test fixture: cannot create image destination"
        case .cannotFinalize: "Test fixture: cannot finalize test image"
        }
    }
}
```

- [ ] **Step 3: Build and run tests**

Run: `swift build 2>&1 | tail -5 && swift test --filter TempFolder 2>&1 | tail -10`
Expected: Build succeeds, tests pass (on macOS, the `#if canImport(CoreGraphics)` branch is taken).

- [ ] **Step 4: Commit**

```bash
git add Tests/piqleyTests/TestHelpers.swift Tests/piqleyTests/Fixtures/test.jpg
git commit -m "feat: platform-conditional test helpers with static JPEG fixture for Linux"
```

---

### Task 12: MetadataExtractorTests — Platform Guard

**Files:**
- Modify: `Tests/piqleyTests/MetadataExtractorTests.swift`

- [ ] **Step 1: Wrap test file in platform conditional**

Add `#if canImport(ImageIO)` before line 1 and `#endif` after the last line:

```swift
#if canImport(ImageIO)
import Testing
import Foundation
@testable import piqley

@Suite("MetadataExtractor")
struct MetadataExtractorTests {
    // ... all existing tests unchanged ...
}
#endif
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter MetadataExtractor 2>&1 | tail -10`
Expected: All tests pass on macOS.

- [ ] **Step 3: Commit**

```bash
git add Tests/piqleyTests/MetadataExtractorTests.swift
git commit -m "build: wrap MetadataExtractorTests in #if canImport(ImageIO) for Linux"
```

---

### Task 13: Final Verification

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 3: Verify no remaining Keychain references in non-guarded code**

Run: `grep -rn "KeychainSecretStore\b" Sources/ | grep -v "#if"` — should return nothing outside the factory function and the `#if os(macOS)` guarded file.

Run: `grep -rn "import Security" Sources/` — should only appear inside the `#if os(macOS)` guarded `KeychainSecretStore.swift`.
