# Cryptographic Image Signing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GPG-based cryptographic signing to processed images with XMP metadata embedding and a verify subcommand.

**Architecture:** After resize, compute a SHA-256 hash of the complete JPEG file bytes (before XMP injection), sign it with GPG, and embed the signature in a custom XMP namespace. A `verify` subcommand strips the signing XMP fields, re-writes the file, and compares the hash. XMP namespace is derived from the Ghost URL at runtime (e.g., `https://quigs.photo` → `https://quigs.photo/xmp/1.0/`). Signing is always-on when configured, opt-out with `--no-sign`.

**Tech Stack:** Swift 6.2, CoreGraphics/ImageIO (XMP via CGImageMetadata APIs), CryptoKit (SHA-256), Foundation.Process (GPG shelling)

---

### Task 1: Add `SigningConfig` to `AppConfig`

**Files:**
- Modify: `Sources/piqley/Config/Config.swift`
- Modify: `Tests/piqleyTests/ConfigTests.swift`

- [ ] **Step 1: Write failing test for SigningConfig decoding with defaults**

In `Tests/piqleyTests/ConfigTests.swift`, add:

```swift
func testSigningConfigDefaultsWhenMissing() throws {
    let json = """
    {
        "ghost": {
            "url": "https://quigs.photo",
            "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
        },
        "processing": { "maxLongEdge": 2000, "jpegQuality": 80 },
        "project365": { "keyword": "365 Project", "referenceDate": "2025-12-25", "emailTo": "t@t.com" },
        "smtp": { "host": "smtp.t.com", "port": 587, "username": "u", "from": "u@t.com" }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    XCTAssertNil(config.signing)
}

func testSigningConfigCustomXmpNames() throws {
    let json = """
    {
        "ghost": {
            "url": "https://quigs.photo",
            "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
        },
        "processing": { "maxLongEdge": 2000, "jpegQuality": 80 },
        "project365": { "keyword": "365 Project", "referenceDate": "2025-12-25", "emailTo": "t@t.com" },
        "smtp": { "host": "smtp.t.com", "port": 587, "username": "u", "from": "u@t.com" },
        "signing": {
            "keyFingerprint": "ABCD1234",
            "xmpNamespace": "http://custom.example/xmp/1.0/",
            "xmpPrefix": "custom"
        }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    XCTAssertEqual(config.signing?.keyFingerprint, "ABCD1234")
    XCTAssertEqual(config.signing?.xmpNamespace, "http://custom.example/xmp/1.0/")
    XCTAssertEqual(config.signing?.xmpPrefix, "custom")
}

func testSigningConfigDefaultXmpNames() throws {
    let json = """
    {
        "ghost": {
            "url": "https://quigs.photo",
            "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
        },
        "processing": { "maxLongEdge": 2000, "jpegQuality": 80 },
        "project365": { "keyword": "365 Project", "referenceDate": "2025-12-25", "emailTo": "t@t.com" },
        "smtp": { "host": "smtp.t.com", "port": 587, "username": "u", "from": "u@t.com" },
        "signing": {
            "keyFingerprint": "ABCD1234"
        }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    XCTAssertEqual(config.signing?.keyFingerprint, "ABCD1234")
    XCTAssertNil(config.signing?.xmpNamespace, "Namespace should be nil when not specified (derived at runtime)")
    XCTAssertEqual(config.signing?.xmpPrefix, "piqley")
}

func testResolvedSigningConfigDerivesNamespace() throws {
    let json = """
    {
        "ghost": {
            "url": "https://quigs.photo",
            "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
        },
        "processing": { "maxLongEdge": 2000, "jpegQuality": 80 },
        "project365": { "keyword": "365 Project", "referenceDate": "2025-12-25", "emailTo": "t@t.com" },
        "smtp": { "host": "smtp.t.com", "port": 587, "username": "u", "from": "u@t.com" },
        "signing": {
            "keyFingerprint": "ABCD1234"
        }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    let resolved = config.resolvedSigningConfig
    XCTAssertEqual(resolved?.xmpNamespace, "https://quigs.photo/xmp/1.0/")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1`
Expected: Compilation error — `AppConfig` has no member `signing`

- [ ] **Step 3: Implement SigningConfig**

In `Sources/piqley/Config/Config.swift`:

Add `SigningConfig` struct after `SMTPConfig` (after line 87):

```swift
struct SigningConfig: Codable, Equatable {
    var keyFingerprint: String
    var xmpNamespace: String?
    var xmpPrefix: String

    static let defaultXmpPrefix = "piqley"

    /// Derive XMP namespace from Ghost URL: "https://quigs.photo" → "https://quigs.photo/xmp/1.0/"
    static func deriveXmpNamespace(from ghostURL: String) -> String {
        let base = ghostURL.hasSuffix("/") ? ghostURL : ghostURL + "/"
        return base + "xmp/1.0/"
    }

    init(keyFingerprint: String, xmpNamespace: String? = nil, xmpPrefix: String = SigningConfig.defaultXmpPrefix) {
        self.keyFingerprint = keyFingerprint
        self.xmpNamespace = xmpNamespace
        self.xmpPrefix = xmpPrefix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyFingerprint = try container.decode(String.self, forKey: .keyFingerprint)
        xmpNamespace = try container.decodeIfPresent(String.self, forKey: .xmpNamespace)
        xmpPrefix = try container.decodeIfPresent(String.self, forKey: .xmpPrefix) ?? SigningConfig.defaultXmpPrefix
    }
}
```

Also add `resolvedSigningConfig` computed property on `AppConfig`:

```swift
/// Resolved signing config with XMP namespace derived from Ghost URL if not explicitly set
var resolvedSigningConfig: SigningConfig? {
    guard var config = signing else { return nil }
    if config.xmpNamespace == nil {
        config.xmpNamespace = SigningConfig.deriveXmpNamespace(from: ghost.url)
    }
    return config
}
```

Add `var signing: SigningConfig?` to `AppConfig` (after line 10, the `cameraModelTags` line).

Update `AppConfig.init(...)` (around line 89) to include `signing: SigningConfig? = nil` parameter and `self.signing = signing`.

Update `AppConfig.init(from decoder:)` (around line 107) to add:
```swift
signing = try container.decodeIfPresent(SigningConfig.self, forKey: .signing)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Config/Config.swift Tests/piqleyTests/ConfigTests.swift
git commit -m "feat(signing): add SigningConfig to AppConfig with configurable XMP namespace"
```

---

### Task 2: Create `SignableContentExtractor`

**Files:**
- Create: `Sources/piqley/ImageProcessing/SignableContentExtractor.swift`
- Create: `Tests/piqleyTests/SignableContentExtractorTests.swift`

- [ ] **Step 1: Write failing tests**

In `Tests/piqleyTests/SignableContentExtractorTests.swift`:

```swift
import XCTest
import ImageIO
@testable import piqley

final class SignableContentExtractorTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testDeterministicHash() throws {
        let path = tmpDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: path, cameraMake: "FUJIFILM", cameraModel: "X-T5")

        let extractor = SignableContentExtractor()
        let hash1 = try extractor.hashFile(at: path)
        let hash2 = try extractor.hashFile(at: path)

        XCTAssertEqual(hash1, hash2, "Same file should produce same hash")
        XCTAssertEqual(hash1.count, 64, "SHA-256 hex should be 64 characters")
    }

    func testDifferentImagesProduceDifferentHashes() throws {
        let path1 = tmpDir.appendingPathComponent("img1.jpg").path
        let path2 = tmpDir.appendingPathComponent("img2.jpg").path
        try TestFixtures.createTestJPEG(at: path1, width: 100, height: 100)
        try TestFixtures.createTestJPEG(at: path2, width: 200, height: 200)

        let extractor = SignableContentExtractor()
        let hash1 = try extractor.hashFile(at: path1)
        let hash2 = try extractor.hashFile(at: path2)

        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashFileStrippingSignature() throws {
        // Create an image, get its hash, add XMP signing fields,
        // then verify stripping produces a deterministic hash
        let path = tmpDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(at: path, cameraMake: "Canon")

        let extractor = SignableContentExtractor()
        let hashBefore = try extractor.hashFile(at: path)

        // Write some XMP in the piqley namespace to the image
        try addXmpSigningFields(
            to: path,
            namespace: "https://quigs.photo/xmp/1.0/",
            prefix: "piqley"
        )

        // Hash after adding XMP should differ (file changed)
        let hashWithXmp = try extractor.hashFile(at: path)
        XCTAssertNotEqual(hashBefore, hashWithXmp)

        // But stripping the signing namespace should produce a deterministic hash
        let hashStripped = try extractor.hashFileStrippingSignature(
            at: path,
            namespace: "https://quigs.photo/xmp/1.0/",
            prefix: "piqley"
        )

        let hashStripped2 = try extractor.hashFileStrippingSignature(
            at: path,
            namespace: "https://quigs.photo/xmp/1.0/",
            prefix: "piqley"
        )
        XCTAssertEqual(hashStripped, hashStripped2, "Stripping should be deterministic")
    }
}
```

- [ ] **Step 2: Add `TestFixtures.addXmpSigningFields` helper**

In `Tests/piqleyTests/TestHelpers.swift`, add after the existing `createTestJPEG` method:

```swift
static func addXmpSigningFields(
    to path: String,
    namespace: String,
    prefix: String
) throws {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let imageType = CGImageSourceGetType(source),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw TestFixtureError.cannotCreateContext
    }

    let metadata = CGImageMetadataCreateMutable()
    let tag = CGImageMetadataTagCreate(
        namespace as CFString,
        prefix as CFString,
        "contentHash" as CFString,
        .string,
        "fakehash123" as CFTypeRef
    )!
    CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):contentHash" as CFString, tag)

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, imageType, 1, nil) else {
        throw TestFixtureError.cannotCreateDestination
    }

    // Copy original properties
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) ?? [:] as CFDictionary

    let addOptions: [String: Any] = [
        kCGImageDestinationMetadata as String: metadata,
        kCGImageDestinationMergeMetadata as String: true,
    ]

    CGImageDestinationAddImageAndMetadata(dest, image, metadata, addOptions as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw TestFixtureError.cannotFinalize }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SignableContentExtractorTests 2>&1`
Expected: Compilation error — `SignableContentExtractor` not found

- [ ] **Step 4: Implement SignableContentExtractor**

Create `Sources/piqley/ImageProcessing/SignableContentExtractor.swift`:

```swift
import CryptoKit
import Foundation
import ImageIO

struct SignableContentExtractor {
    enum ExtractionError: Error, CustomStringConvertible {
        case cannotReadFile(String)
        case cannotProcessImage(String)

        var description: String {
            switch self {
            case .cannotReadFile(let path): return "Cannot read file at \(path)"
            case .cannotProcessImage(let path): return "Cannot process image at \(path)"
            }
        }
    }

    /// SHA-256 hash of the raw file bytes. Used during signing (before XMP injection).
    func hashFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Strip XMP signing fields from the image, write to a temp file, and hash that.
    /// Used during verification to reconstruct the pre-signing file hash.
    func hashFileStrippingSignature(at path: String, namespace: String, prefix: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageType = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExtractionError.cannotReadFile(path)
        }

        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // Read existing metadata and filter out signing namespace tags
        let existingMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let filteredMetadata = CGImageMetadataCreateMutable()

        if let existingMetadata {
            let allTags = CGImageMetadataCopyTags(existingMetadata) as? [CGImageMetadataTag] ?? []
            for tag in allTags {
                guard let tagPrefix = CGImageMetadataTagCopyPrefix(tag) as String? else { continue }
                if tagPrefix == prefix { continue }
                guard let tagName = CGImageMetadataTagCopyName(tag) as String? else { continue }
                CGImageMetadataSetTagWithPath(filteredMetadata, nil, "\(tagPrefix):\(tagName)" as CFString, tag)
            }
        }

        // Write to temp file without signing XMP
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-verify-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        guard let dest = CGImageDestinationCreateWithURL(tmpPath as CFURL, imageType, 1, nil) else {
            throw ExtractionError.cannotProcessImage(path)
        }

        CGImageDestinationAddImageAndMetadata(dest, cgImage, filteredMetadata, existingProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExtractionError.cannotProcessImage(path)
        }

        return try hashFile(at: tmpPath.path)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SignableContentExtractorTests 2>&1`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/ImageProcessing/SignableContentExtractor.swift Tests/piqleyTests/SignableContentExtractorTests.swift Tests/piqleyTests/TestHelpers.swift
git commit -m "feat(signing): add SignableContentExtractor for deterministic image hashing"
```

---

### Task 3: Create `ImageSigner` protocol and `GPGImageSigner`

**Files:**
- Create: `Sources/piqley/ImageProcessing/ImageSigner.swift`
- Create: `Sources/piqley/ImageProcessing/GPGImageSigner.swift`
- Create: `Tests/piqleyTests/ImageSignerTests.swift`

- [ ] **Step 1: Write failing tests**

In `Tests/piqleyTests/ImageSignerTests.swift`:

```swift
import XCTest
import ImageIO
@testable import piqley

final class ImageSignerTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testSignEmbeddsXmpFields() async throws {
        // Skip if gpg is not installed
        guard GPGImageSigner.isGPGAvailable() else {
            throw XCTSkip("GPG not installed, skipping signing test")
        }
        // Skip if no secret keys available
        guard let fingerprint = try? GPGImageSigner.firstAvailableKeyFingerprint() else {
            throw XCTSkip("No GPG secret keys available, skipping signing test")
        }

        let path = tmpDir.appendingPathComponent("sign-test.jpg").path
        try TestFixtures.createTestJPEG(at: path, cameraMake: "FUJIFILM")

        let signingConfig = AppConfig.SigningConfig(keyFingerprint: fingerprint, xmpNamespace: "https://test.example/xmp/1.0/")
        let signer = GPGImageSigner(config: signingConfig)
        let result = try await signer.sign(imageAt: path)

        XCTAssertFalse(result.contentHash.isEmpty)
        XCTAssertFalse(result.signature.isEmpty)
        XCTAssertEqual(result.keyFingerprint, fingerprint)
        XCTAssertTrue(result.signature.contains("BEGIN PGP SIGNATURE"))

        // Verify XMP was written to the file
        let xmp = try XMPSignatureReader.read(
            from: path,
            namespace: signingConfig.xmpNamespace!,
            prefix: signingConfig.xmpPrefix
        )
        XCTAssertEqual(xmp?.contentHash, result.contentHash)
        XCTAssertEqual(xmp?.signature, result.signature)
        XCTAssertEqual(xmp?.keyFingerprint, fingerprint)
        XCTAssertEqual(xmp?.algorithm, "GPG-SHA256")
    }

    func testSigningPreservesImageData() async throws {
        guard GPGImageSigner.isGPGAvailable() else {
            throw XCTSkip("GPG not installed")
        }
        guard let fingerprint = try? GPGImageSigner.firstAvailableKeyFingerprint() else {
            throw XCTSkip("No GPG secret keys available")
        }

        let path = tmpDir.appendingPathComponent("preserve-test.jpg").path
        try TestFixtures.createTestJPEG(at: path, width: 500, height: 300, cameraMake: "Canon")

        // Read image dimensions before signing
        let sourceBefore = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let propsBefore = CGImageSourceCopyPropertiesAtIndex(sourceBefore, 0, nil) as! [String: Any]
        let widthBefore = propsBefore[kCGImagePropertyPixelWidth as String] as! Int

        let signingConfig = AppConfig.SigningConfig(keyFingerprint: fingerprint, xmpNamespace: "https://test.example/xmp/1.0/")
        let signer = GPGImageSigner(config: signingConfig)
        _ = try await signer.sign(imageAt: path)

        // Image dimensions should be unchanged
        let sourceAfter = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let propsAfter = CGImageSourceCopyPropertiesAtIndex(sourceAfter, 0, nil) as! [String: Any]
        let widthAfter = propsAfter[kCGImagePropertyPixelWidth as String] as! Int

        XCTAssertEqual(widthBefore, widthAfter)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ImageSignerTests 2>&1`
Expected: Compilation error — `GPGImageSigner`, `XMPSignatureReader` not found

- [ ] **Step 3: Create ImageSigner protocol**

Create `Sources/piqley/ImageProcessing/ImageSigner.swift`:

```swift
import Foundation

struct SigningResult {
    let contentHash: String
    let signature: String
    let keyFingerprint: String
}

protocol ImageSigner {
    func sign(imageAt path: String) async throws -> SigningResult
}
```

- [ ] **Step 4: Create XMPSignatureReader (used by both signer and verifier)**

Create `Sources/piqley/ImageProcessing/XMPSignatureReader.swift`:

```swift
import Foundation
import ImageIO

struct XMPSignatureFields {
    let contentHash: String
    let signature: String
    let keyFingerprint: String
    let algorithm: String
}

enum XMPSignatureReader {
    static func read(from path: String, namespace: String, prefix: String) throws -> XMPSignatureFields? {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else {
            return nil
        }

        let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []

        var contentHash: String?
        var signature: String?
        var keyFingerprint: String?
        var algorithm: String?

        for tag in tags {
            guard let tagPrefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  tagPrefix == prefix,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  let value = CGImageMetadataTagCopyValue(tag) as? String else {
                continue
            }
            switch name {
            case "contentHash": contentHash = value
            case "signature": signature = value
            case "keyFingerprint": keyFingerprint = value
            case "algorithm": algorithm = value
            default: break
            }
        }

        guard let hash = contentHash, let sig = signature, let fp = keyFingerprint, let alg = algorithm else {
            return nil
        }
        return XMPSignatureFields(contentHash: hash, signature: sig, keyFingerprint: fp, algorithm: alg)
    }
}
```

- [ ] **Step 5: Create GPGImageSigner**

Create `Sources/piqley/ImageProcessing/GPGImageSigner.swift`:

```swift
import Foundation
import ImageIO

struct GPGImageSigner: ImageSigner {
    let config: AppConfig.SigningConfig

    enum SigningError: Error, CustomStringConvertible {
        case gpgNotFound
        case gpgFailed(String)
        case xmpWriteFailed(String)

        var description: String {
            switch self {
            case .gpgNotFound: return "GPG not found. Install with: brew install gnupg"
            case .gpgFailed(let msg): return "GPG signing failed: \(msg)"
            case .xmpWriteFailed(let msg): return "Failed to write XMP signature: \(msg)"
            }
        }
    }

    func sign(imageAt path: String) async throws -> SigningResult {
        guard GPGImageSigner.isGPGAvailable() else {
            throw SigningError.gpgNotFound
        }
        guard let namespace = config.xmpNamespace else {
            throw SigningError.xmpWriteFailed("XMP namespace not configured. Ensure signing config has a resolved namespace.")
        }

        // 1. Hash the file before any XMP modification
        let extractor = SignableContentExtractor()
        let contentHash = try extractor.hashFile(at: path)

        // 2. Sign with GPG
        let signature = try await gpgSign(data: contentHash, keyFingerprint: config.keyFingerprint)

        // 3. Embed XMP
        try writeXMPSignature(
            to: path,
            contentHash: contentHash,
            signature: signature,
            keyFingerprint: config.keyFingerprint,
            namespace: namespace,
            prefix: config.xmpPrefix
        )

        return SigningResult(
            contentHash: contentHash,
            signature: signature,
            keyFingerprint: config.keyFingerprint
        )
    }

    private func gpgSign(data: String, keyFingerprint: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--detach-sign", "--armor", "-u", keyFingerprint, "--batch", "--yes"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(data.utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SigningError.gpgFailed(stderr)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeXMPSignature(
        to path: String,
        contentHash: String,
        signature: String,
        keyFingerprint: String,
        namespace: String,
        prefix: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageType = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SigningError.xmpWriteFailed("Cannot read image")
        }

        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // Build XMP metadata
        let xmpMetadata = CGImageMetadataCreateMutable()
        let fields: [(String, String)] = [
            ("contentHash", contentHash),
            ("signature", signature),
            ("keyFingerprint", keyFingerprint),
            ("algorithm", "GPG-SHA256"),
        ]
        for (name, value) in fields {
            guard let tag = CGImageMetadataTagCreate(
                namespace as CFString,
                prefix as CFString,
                name as CFString,
                .string,
                value as CFTypeRef
            ) else {
                throw SigningError.xmpWriteFailed("Cannot create XMP tag: \(name)")
            }
            CGImageMetadataSetTagWithPath(xmpMetadata, nil, "\(prefix):\(name)" as CFString, tag)
        }

        // Write image with original properties + new XMP
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, imageType, 1, nil) else {
            throw SigningError.xmpWriteFailed("Cannot create image destination")
        }

        CGImageDestinationAddImageAndMetadata(dest, cgImage, xmpMetadata, existingProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SigningError.xmpWriteFailed("Cannot finalize image")
        }
    }

    // MARK: - Static helpers

    static func isGPGAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func firstAvailableKeyFingerprint() throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--list-secret-keys", "--keyid-format", "long", "--with-colons"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse colon-delimited output for fpr lines
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("fpr:") {
                let fields = line.components(separatedBy: ":")
                if fields.count > 9 {
                    return fields[9]
                }
            }
        }
        return nil
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ImageSignerTests 2>&1`
Expected: All tests pass (or skip if no GPG key)

- [ ] **Step 7: Commit**

```bash
git add Sources/piqley/ImageProcessing/ImageSigner.swift Sources/piqley/ImageProcessing/GPGImageSigner.swift Sources/piqley/ImageProcessing/XMPSignatureReader.swift Tests/piqleyTests/ImageSignerTests.swift
git commit -m "feat(signing): add GPGImageSigner with XMP embedding and reading"
```

---

### Task 4: Integrate signing into `ProcessCommand`

**Files:**
- Modify: `Sources/piqley/CLI/ProcessCommand.swift`

- [ ] **Step 1: Add `--no-sign` flag**

In `Sources/piqley/CLI/ProcessCommand.swift`, add after the `resultsDir` option (after line 24):

```swift
@Flag(help: "Skip image signing for this run")
var noSign = false
```

- [ ] **Step 2: Add signing logic after resize**

After the resize block (after line 196, the closing `}` of the resize `if !dryRun` block), add:

```swift
// Sign image
if let signingConfig = config.resolvedSigningConfig, !noSign {
    if !dryRun {
        logger.info("[\(image.filename)] Signing...")
        let signer = GPGImageSigner(config: signingConfig)
        let signingResult = try await signer.sign(imageAt: resizedPath)
        logger.debug("[\(image.filename)] Content hash: \(signingResult.contentHash)")
    } else {
        print("[\(image.filename)] Would sign with key \(config.signing!.keyFingerprint.prefix(16))...")
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/CLI/ProcessCommand.swift
git commit -m "feat(signing): integrate signing into process command with --no-sign flag"
```

---

### Task 5: Create `VerifyCommand`

**Files:**
- Create: `Sources/piqley/CLI/VerifyCommand.swift`
- Modify: `Sources/piqley/Piqley.swift`

- [ ] **Step 1: Create VerifyCommand**

Create `Sources/piqley/CLI/VerifyCommand.swift`:

```swift
import ArgumentParser
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify the cryptographic signature of a signed image"
    )

    @Argument(help: "Path to JPEG image to verify")
    var imagePath: String

    @Option(help: "Assert the signature was made by this specific GPG key fingerprint")
    var keyFingerprint: String?

    @Option(help: "XMP namespace to look for signature in (default: derived from Ghost URL in config)")
    var xmpNamespace: String?

    @Option(help: "XMP prefix to look for signature in (default: piqley)")
    var xmpPrefix: String?

    func run() throws {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw ValidationError("File not found: \(imagePath)")
        }

        // Resolve XMP namespace/prefix: CLI flags > config > error
        let namespace: String
        let prefix: String

        if let ns = xmpNamespace {
            namespace = ns
        } else if FileManager.default.fileExists(atPath: AppConfig.configPath.path),
                  let config = try? AppConfig.load(from: AppConfig.configPath.path),
                  let resolved = config.resolvedSigningConfig,
                  let ns = resolved.xmpNamespace {
            namespace = ns
        } else if FileManager.default.fileExists(atPath: AppConfig.configPath.path),
                  let config = try? AppConfig.load(from: AppConfig.configPath.path) {
            namespace = AppConfig.SigningConfig.deriveXmpNamespace(from: config.ghost.url)
        } else {
            print("No config found and --xmp-namespace not specified.")
            throw ExitCode(1)
        }

        prefix = xmpPrefix ?? {
            if FileManager.default.fileExists(atPath: AppConfig.configPath.path),
               let config = try? AppConfig.load(from: AppConfig.configPath.path),
               let signing = config.signing {
                return signing.xmpPrefix
            }
            return AppConfig.SigningConfig.defaultXmpPrefix
        }()

        // Read XMP signature
        guard let xmp = try XMPSignatureReader.read(
            from: imagePath,
            namespace: namespace,
            prefix: prefix
        ) else {
            print("No signature found in image.")
            throw ExitCode(1)
        }

        // Recompute content hash
        let extractor = SignableContentExtractor()
        let computedHash = try extractor.hashFileStrippingSignature(
            at: imagePath,
            namespace: namespace,
            prefix: prefix
        )

        // Check integrity
        let integrityPass = computedHash == xmp.contentHash
        print("Signed by: \(xmp.keyFingerprint)")
        print("Algorithm: \(xmp.algorithm)")
        print("Content integrity: \(integrityPass ? "PASS" : "FAIL")")

        if !integrityPass {
            print("WARNING: Image content has been modified since signing!")
            throw ExitCode(1)
        }

        // Verify GPG signature
        guard GPGImageSigner.isGPGAvailable() else {
            print("Signature validity: CANNOT VERIFY (GPG not installed)")
            throw ExitCode(1)
        }

        let signatureValid = try verifyGPGSignature(
            signature: xmp.signature,
            data: xmp.contentHash,
            expectedFingerprint: keyFingerprint
        )

        if signatureValid {
            print("Signature validity: VALID")
        } else {
            print("Signature validity: INVALID")
            throw ExitCode(1)
        }
    }

    private func verifyGPGSignature(signature: String, data: String, expectedFingerprint: String?) throws -> Bool {
        // Write signature to temp file
        let tmpDir = FileManager.default.temporaryDirectory
        let sigFile = tmpDir.appendingPathComponent("piqley-verify-\(UUID().uuidString).sig")
        let dataFile = tmpDir.appendingPathComponent("piqley-verify-\(UUID().uuidString).dat")
        defer {
            try? FileManager.default.removeItem(at: sigFile)
            try? FileManager.default.removeItem(at: dataFile)
        }

        try Data(signature.utf8).write(to: sigFile)
        try Data(data.utf8).write(to: dataFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--verify", "--batch", sigFile.path, dataFile.path]

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            if stderr.contains("No public key") {
                print("Signature validity: UNKNOWN KEY")
                return false
            }
            return false
        }

        // If a specific fingerprint is required, check it
        if let expected = expectedFingerprint {
            return stderr.contains(expected)
        }

        return true
    }
}
```

- [ ] **Step 2: Register VerifyCommand in main entry point**

In `Sources/piqley/Piqley.swift`, change line 11:

From:
```swift
subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self]
```
To:
```swift
subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self, VerifyCommand.self]
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/CLI/VerifyCommand.swift Sources/piqley/Piqley.swift
git commit -m "feat(signing): add verify subcommand for signature verification"
```

---

### Task 6: Add signing section to `SetupCommand`

**Files:**
- Modify: `Sources/piqley/CLI/SetupCommand.swift`

- [ ] **Step 1: Add signing setup section**

In `Sources/piqley/CLI/SetupCommand.swift`, after the tag blocklist section (after line 40) and before the config construction (line 42), add:

```swift
// Signing (optional)
var signingConfig: AppConfig.SigningConfig? = nil
let enableSigning = prompt("Enable image signing? (y/n):", default: "n")
if enableSigning.lowercased() == "y" {
    // List available GPG keys
    print("\nAvailable GPG secret keys:")
    let listProcess = Process()
    listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    listProcess.arguments = ["gpg", "--list-secret-keys", "--keyid-format", "long"]
    listProcess.standardError = FileHandle.standardError
    do {
        try listProcess.run()
        listProcess.waitUntilExit()
    } catch {
        print("Could not list GPG keys. Is gnupg installed?")
    }

    let fingerprint = prompt("GPG key fingerprint:")
    if !fingerprint.isEmpty {
        let derivedNs = AppConfig.SigningConfig.deriveXmpNamespace(from: ghostURL)
        let customNs = prompt("XMP namespace (default: \(derivedNs)):", default: derivedNs)
        let customPrefix = prompt("XMP prefix (default: \(AppConfig.SigningConfig.defaultXmpPrefix)):", default: AppConfig.SigningConfig.defaultXmpPrefix)
        signingConfig = AppConfig.SigningConfig(
            keyFingerprint: fingerprint,
            xmpNamespace: customNs,
            xmpPrefix: customPrefix
        )
    }
}
```

- [ ] **Step 2: Pass signingConfig to AppConfig constructor**

Update the `AppConfig(...)` call (around line 42) to include `signing: signingConfig` by adding it after `tagBlocklist: blocklist`. Since `AppConfig.init` doesn't have a `signing` parameter yet, update the init call to set it after construction:

Actually, since we added `signing` to `AppConfig` in Task 1 with a default of `nil`, update the init call. Change:

```swift
let config = AppConfig(
    ghost: .init(
        url: ghostURL,
        schedulingWindow: .init(start: windowStart, end: windowEnd, timezone: timezone)
    ),
    processing: .init(maxLongEdge: maxLongEdge, jpegQuality: jpegQuality),
    project365: .init(keyword: keyword365, referenceDate: refDate, emailTo: emailTo),
    smtp: .init(host: smtpHost, port: smtpPort, username: smtpUsername, from: smtpFrom),
    tagBlocklist: blocklist
)
```

To:

```swift
var config = AppConfig(
    ghost: .init(
        url: ghostURL,
        schedulingWindow: .init(start: windowStart, end: windowEnd, timezone: timezone)
    ),
    processing: .init(maxLongEdge: maxLongEdge, jpegQuality: jpegQuality),
    project365: .init(keyword: keyword365, referenceDate: refDate, emailTo: emailTo),
    smtp: .init(host: smtpHost, port: smtpPort, username: smtpUsername, from: smtpFrom),
    tagBlocklist: blocklist
)
config.signing = signingConfig
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/CLI/SetupCommand.swift
git commit -m "feat(signing): add signing section to interactive setup"
```

---

### Task 7: Add `gnupg` to Homebrew formula

**Files:**
- Modify: `Formula/piqley.rb`

- [ ] **Step 1: Add gnupg dependency**

In `Formula/piqley.rb`, after line 20 (`depends_on :macos`), add:

```ruby
depends_on "gnupg"
```

- [ ] **Step 2: Commit**

```bash
git add Formula/piqley.rb
git commit -m "feat(signing): add gnupg as Homebrew dependency"
```

---

### Task 8: Run full test suite and fix issues

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass

- [ ] **Step 2: Fix any compilation or test failures**

Address any issues found.

- [ ] **Step 3: Run build in release mode**

Run: `swift build -c release 2>&1`
Expected: Build succeeds

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix(signing): address test and build issues"
```
(Only if there were fixes needed)
