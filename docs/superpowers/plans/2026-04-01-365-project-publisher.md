# 365 Project Publisher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the Fingerprinting module from the Ghost CMS plugin into piqley-plugin-sdk, then create a new 365 Project Publisher plugin that emails images via SMTP with perceptual deduplication.

**Architecture:** Two-phase approach. Phase 1 extracts the Fingerprinting target from the ghost plugin into the SDK as a standalone library product with zero dependencies. Phase 2 creates the 365 Project Publisher plugin following the established plugin pattern (PluginHooks + executable + ManifestGen), depending on the SDK for both PiqleyPluginSDK and Fingerprinting, plus Kitura/Swift-SMTP for email delivery.

**Tech Stack:** Swift 6.0, macOS 15+, PiqleyPluginSDK, Fingerprinting (extracted), Kitura/Swift-SMTP 6.0+, SwiftNIO (transitive via Swift-SMTP)

**Spec:** `docs/superpowers/specs/2026-04-01-365-project-publisher-design.md`

---

## Phase 1: Extract Fingerprinting to piqley-plugin-sdk

### Task 1: Add Fingerprinting target to SDK

**Files:**
- Create: `piqley-plugin-sdk/swift/Fingerprinting/DCT.swift`
- Create: `piqley-plugin-sdk/swift/Fingerprinting/PHash.swift`
- Create: `piqley-plugin-sdk/swift/Fingerprinting/ImageFingerprint.swift`
- Create: `piqley-plugin-sdk/swift/Fingerprinting/ImageFingerprinter.swift`
- Create: `piqley-plugin-sdk/swift/Fingerprinting/UploadCache.swift`
- Create: `piqley-plugin-sdk/swift/FingerprintingTests/DCTTests.swift`
- Create: `piqley-plugin-sdk/swift/FingerprintingTests/PHashTests.swift`
- Create: `piqley-plugin-sdk/swift/FingerprintingTests/ImageFingerprintTests.swift`
- Create: `piqley-plugin-sdk/swift/FingerprintingTests/UploadCacheTests.swift`
- Modify: `piqley-plugin-sdk/Package.swift`

- [ ] **Step 1: Copy source files from ghost plugin to SDK**

Copy the 5 source files verbatim from `plugins/photo.quigs.ghostcms.publisher/Sources/Fingerprinting/` to `piqley-plugin-sdk/swift/Fingerprinting/`:

- `DCT.swift`
- `PHash.swift`
- `ImageFingerprint.swift`
- `ImageFingerprinter.swift`
- `UploadCache.swift`

No modifications needed — these files have zero dependencies on PiqleyPluginSDK or PiqleyCore.

- [ ] **Step 2: Copy test files from ghost plugin to SDK**

Copy the 4 test files from `plugins/photo.quigs.ghostcms.publisher/Tests/FingerprintTests/` to `piqley-plugin-sdk/swift/FingerprintingTests/`:

- `DCTTests.swift`
- `PHashTests.swift`
- `ImageFingerprintTests.swift`
- `UploadCacheTests.swift`

No modifications needed — all tests use `@testable import Fingerprinting` which will resolve to the new target.

- [ ] **Step 3: Update SDK Package.swift**

Add the `Fingerprinting` library product, target, and test target to `piqley-plugin-sdk/Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PiqleyPluginSDK",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PiqleyPluginSDK", targets: ["PiqleyPluginSDK"]),
        .library(name: "Fingerprinting", targets: ["Fingerprinting"]),
        .executable(name: "piqley-build", targets: ["piqley-build"]),
    ],
    dependencies: [
        .package(url: "https://github.com/josephquigley/piqley-core", .upToNextMajor(from: "0.17.0")),
        .package(url: "https://github.com/kylef/JSONSchema.swift", .upToNextMajor(from: "0.6.0")),
    ],
    targets: [
        .target(
            name: "PiqleyPluginSDK",
            dependencies: [.product(name: "PiqleyCore", package: "piqley-core")],
            path: "swift/PiqleyPluginSDK"
        ),
        .target(
            name: "Fingerprinting",
            path: "swift/Fingerprinting"
        ),
        .executableTarget(
            name: "piqley-build",
            dependencies: ["PiqleyPluginSDK"],
            path: "swift/PiqleyBuild"
        ),
        .testTarget(
            name: "PiqleyPluginSDKTests",
            dependencies: [
                "PiqleyPluginSDK",
                .product(name: "JSONSchema", package: "JSONSchema.swift"),
            ],
            path: "swift/Tests",
            resources: [.copy("schemas")]
        ),
        .testTarget(
            name: "FingerprintingTests",
            dependencies: ["Fingerprinting"],
            path: "swift/FingerprintingTests"
        ),
    ]
)
```

- [ ] **Step 4: Verify SDK builds and tests pass**

Run from `piqley-plugin-sdk/`:
```bash
swift build
swift test
```

Expected: All existing PiqleyPluginSDKTests pass, all 4 new FingerprintingTests suites pass (DCT, PHash, ImageFingerprint, UploadCache).

- [ ] **Step 5: Commit**

```
feat(sdk): add Fingerprinting library product

Extract perceptual hashing (pHash/DCT), ImageFingerprint, and
UploadCache from ghost plugin into the SDK as a reusable library.
Zero external dependencies — pure Swift + CoreGraphics.
```

### Task 2: Update Ghost plugin to use SDK Fingerprinting

**Files:**
- Delete: `plugins/photo.quigs.ghostcms.publisher/Sources/Fingerprinting/` (entire directory)
- Delete: `plugins/photo.quigs.ghostcms.publisher/Tests/FingerprintTests/` (entire directory)
- Modify: `plugins/photo.quigs.ghostcms.publisher/Package.swift`

- [ ] **Step 1: Delete local Fingerprinting source and test directories**

Remove:
- `plugins/photo.quigs.ghostcms.publisher/Sources/Fingerprinting/`
- `plugins/photo.quigs.ghostcms.publisher/Tests/FingerprintTests/`

- [ ] **Step 2: Update ghost plugin Package.swift**

Replace the local `Fingerprinting` target and `FingerprintTests` test target with a product dependency from the SDK:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ghost-cms-publisher",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/josephquigley/piqley-plugin-sdk",
            .upToNextMajor(from: "0.14.2")
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            .upToNextMajor(from: "4.3.0")
        ),
    ],
    targets: [
        .target(
            name: "PluginHooks",
            dependencies: [
                .product(name: "PiqleyPluginSDK", package: "piqley-plugin-sdk"),
            ],
            path: "Sources/PluginHooks"
        ),
        .executableTarget(
            name: "ghost-cms-publisher",
            dependencies: [
                "PluginHooks",
                .product(name: "Fingerprinting", package: "piqley-plugin-sdk"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ghost-cms-publisher"
        ),
        .executableTarget(
            name: "piqley-manifest-gen",
            dependencies: ["PluginHooks"],
            path: "Sources/ManifestGen"
        ),
    ]
)
```

Note: The `FingerprintTests` target is removed because the tests now live in the SDK. The `import Fingerprinting` statements in `Plugin.swift` remain unchanged.

- [ ] **Step 3: Verify ghost plugin builds**

Run from `plugins/photo.quigs.ghostcms.publisher/`:
```bash
swift build
```

Expected: Build succeeds. All `import Fingerprinting` statements resolve to the SDK product.

- [ ] **Step 4: Commit**

```
refactor(ghost): use SDK Fingerprinting instead of local copy

Remove local Fingerprinting sources and tests. The ghost plugin now
depends on the Fingerprinting library product from piqley-plugin-sdk.
No behavioral changes — all imports resolve identically.
```

---

## Phase 2: 365 Project Publisher Plugin

### Task 3: Scaffold plugin with PluginHooks

**Files:**
- Create: `plugins/photo.quigs.365-project-publisher/Sources/PluginHooks/ProjectField.swift`
- Create: `plugins/photo.quigs.365-project-publisher/Sources/PluginHooks/Hooks.swift`

- [ ] **Step 1: Create ProjectField.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/PluginHooks/ProjectField.swift`:

```swift
import PiqleyPluginSDK

/// State fields consumed by the 365 Project Publisher plugin.
public enum ProjectField: String, StateKey, CaseIterable {
    public static let namespace = "photo.quigs.365-project-publisher"

    case recipient
    case subject
    case body
    case isIgnored = "is_ignored"
}
```

- [ ] **Step 2: Create Hooks.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/PluginHooks/Hooks.swift`:

```swift
import PiqleyPluginSDK
import PiqleyCore

extension PluginDirectory {
    static let pluginBinary = "\(bin)/365-project-publisher"
}

public let pluginFields = FieldRegistry {
    Consumes(ProjectField.recipient, type: "string", description: "Email address to send to")
    Consumes(ProjectField.subject, type: "string", description: "Email subject line")
    Consumes(ProjectField.body, type: "string", description: "Email body text (plain text, allowed to be empty)")
    Consumes(ProjectField.isIgnored, type: "bool", description: "Skip this image")
}

public let pluginConfig = ConfigRegistry {
    Config("SMTP_HOST", type: .string, default: .string(""), label: "SMTP Host", description: "SMTP server hostname")
    Config("SMTP_PORT", type: .int, default: 587, label: "SMTP Port", description: "SMTP server port")
    Config("SMTP_USERNAME", type: .string, default: .string(""), label: "SMTP Username", description: "SMTP username")
    Config("SMTP_FROM", type: .string, default: .string(""), label: "SMTP From", description: "Sender email address")
    Secret("SMTP_PASSWORD", type: .string, label: "SMTP Password", description: "SMTP password")
    Config("FINGERPRINT_SENSITIVITY", type: .string, default: .string("moderate"), label: "Fingerprint Sensitivity", description: "Perceptual hash sensitivity: conservative, moderate, or aggressive")
}

public let pluginRegistry = HookRegistry { r in
    r.register(StandardHook.self) { hook in
        switch hook {
        case .publish:
            return buildStage { Binary(command: PluginDirectory.pluginBinary) }
        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Commit**

```
feat(365): add PluginHooks with state fields and config entries

Define ProjectField state keys (recipient, subject, body, is_ignored),
SMTP config entries, fingerprint sensitivity config, and publish stage
hook registration.
```

### Task 4: Create ManifestGen and build manifest

**Files:**
- Create: `plugins/photo.quigs.365-project-publisher/Sources/ManifestGen/main.swift`
- Create: `plugins/photo.quigs.365-project-publisher/piqley-build-manifest.json`

- [ ] **Step 1: Create ManifestGen main.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/ManifestGen/main.swift`:

```swift
import Foundation
import PluginHooks

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("Usage: piqley-manifest-gen <output-directory>\n".utf8))
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try pluginRegistry.writeStageFiles(to: outputDir)
try pluginConfig.writeConfigEntries(to: outputDir)
try pluginFields.writeFields(to: outputDir)
```

- [ ] **Step 2: Create piqley-build-manifest.json**

Create `plugins/photo.quigs.365-project-publisher/piqley-build-manifest.json`:

```json
{
  "identifier": "photo.quigs.365-project-publisher",
  "pluginName": "365 Project Publisher",
  "pluginSchemaVersion": "1",
  "type": "static",
  "pluginVersion": "0.1.0",
  "bin": {
    "macos-arm64": [".build/arm64-apple-macosx/release/365-project-publisher"]
  },
  "data": {},
  "dependencies": []
}
```

- [ ] **Step 3: Commit**

```
feat(365): add ManifestGen and build manifest

piqley-manifest-gen generates stage, config, and field JSON files.
piqley-build-manifest.json declares the plugin identity and binary path.
```

### Task 5: Create Constants and EmailSender

**Files:**
- Create: `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/Constants.swift`
- Create: `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/EmailSender.swift`

- [ ] **Step 1: Create Constants.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/Constants.swift`:

```swift
enum Constants {

    enum ConfigKey {
        static let smtpHost = "SMTP_HOST"
        static let smtpPort = "SMTP_PORT"
        static let smtpUsername = "SMTP_USERNAME"
        static let smtpFrom = "SMTP_FROM"
        static let smtpPassword = "SMTP_PASSWORD"
        static let fingerprintSensitivity = "FINGERPRINT_SENSITIVITY"
    }

    enum CachePath {
        static let uploadCache = "upload-cache.json"
    }

    enum MIMEType {
        static let jpeg = "image/jpeg"
    }

    enum Sensitivity: String, CaseIterable {
        case conservative
        case moderate
        case aggressive

        var threshold: Int {
            switch self {
            case .conservative: return 5
            case .moderate: return 10
            case .aggressive: return 18
            }
        }

        static let `default`: Sensitivity = .moderate
    }
}
```

- [ ] **Step 2: Create EmailSender.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/EmailSender.swift`:

```swift
import Foundation
import NIO
import SwiftSMTP

struct EmailSender: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let from: String

    func send(
        recipient: String,
        subject: String,
        body: String,
        attachmentPath: String,
        attachmentFilename: String
    ) throws {
        let smtpConfig = Configuration(
            server: .init(
                hostname: host,
                port: port,
                encryption: .startTLS(.always)
            ),
            credentials: .init(username: username, password: password),
            featureFlags: [.useESMTP]
        )

        let imageData = try Data(contentsOf: URL(fileURLWithPath: attachmentPath))

        let email = Email(
            sender: .init(emailAddress: from),
            recipients: [.init(emailAddress: recipient)],
            subject: subject,
            body: .plain(body),
            attachments: [
                .init(
                    name: attachmentFilename,
                    contentType: Constants.MIMEType.jpeg,
                    data: imageData
                ),
            ]
        )

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }

        let mailer = Mailer(group: eventLoopGroup, configuration: smtpConfig)
        let future = mailer.send(email)
        try future.wait()
    }
}

enum EmailSenderError: Error, LocalizedError {
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case let .sendFailed(msg): "Email send failed: \(msg)"
        }
    }
}
```

- [ ] **Step 3: Commit**

```
feat(365): add Constants and EmailSender

Constants defines config keys, cache paths, MIME types, and fingerprint
sensitivity thresholds. EmailSender adapts the old SMTP implementation
using Kitura/Swift-SMTP with STARTTLS and ESMTP.
```

### Task 6: Create Plugin handler and main.swift

**Files:**
- Create: `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/Plugin.swift`
- Create: `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/main.swift`

- [ ] **Step 1: Create Plugin.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/Plugin.swift`:

```swift
import Fingerprinting
import Foundation
import PiqleyCore
import PiqleyPluginSDK
import PluginHooks

struct Plugin: PiqleyPlugin {
    let registry = pluginRegistry

    private static let pluginNamespace = ProjectField.namespace

    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        switch request.hook {
        case let h as StandardHook:
            switch h {
            case .publish:
                return try await publish(request)
            case .pipelineStart, .preProcess, .postProcess, .postPublish, .pipelineFinished:
                return .ok
            }
        default:
            throw SDKError.unhandledHook(request.hook.rawValue)
        }
    }

    // MARK: - Publish

    private func publish(_ request: PluginRequest) async throws -> PluginResponse {
        guard let smtpHost = request.pluginConfig[Constants.ConfigKey.smtpHost]?.stringValue,
              !smtpHost.isEmpty
        else {
            return PluginResponse(success: false, error: "Missing \(Constants.ConfigKey.smtpHost) in plugin config")
        }

        let smtpPort = request.pluginConfig[Constants.ConfigKey.smtpPort]?.intValue ?? 587

        guard let smtpUsername = request.pluginConfig[Constants.ConfigKey.smtpUsername]?.stringValue,
              !smtpUsername.isEmpty
        else {
            return PluginResponse(success: false, error: "Missing \(Constants.ConfigKey.smtpUsername) in plugin config")
        }

        guard let smtpFrom = request.pluginConfig[Constants.ConfigKey.smtpFrom]?.stringValue,
              !smtpFrom.isEmpty
        else {
            return PluginResponse(success: false, error: "Missing \(Constants.ConfigKey.smtpFrom) in plugin config")
        }

        guard let smtpPassword = request.secrets[Constants.ConfigKey.smtpPassword] else {
            return PluginResponse(success: false, error: "Missing \(Constants.ConfigKey.smtpPassword) in secrets")
        }

        let emailSender = EmailSender(
            host: smtpHost,
            port: smtpPort,
            username: smtpUsername,
            password: smtpPassword,
            from: smtpFrom
        )

        let uploadCachePath = "\(request.dataPath)/\(Constants.CachePath.uploadCache)"
        var uploadCache = UploadCache(filePath: uploadCachePath)

        let sensitivityStr = request.pluginConfig[Constants.ConfigKey.fingerprintSensitivity]?.stringValue ?? "moderate"
        let sensitivity = Constants.Sensitivity(rawValue: sensitivityStr) ?? .default

        #if canImport(CoreGraphics)
        let fingerprinter: ImageFingerprinter = PerceptualFingerprinter()
        #else
        let fingerprinter: ImageFingerprinter = FilenameFingerprinter()
        #endif

        let images = try request.imageFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }

        for imageURL in images {
            let filename = imageURL.lastPathComponent

            // 1. Fingerprint and check dedup cache
            let fingerprint: ImageFingerprint
            do {
                fingerprint = try fingerprinter.fingerprint(of: imageURL)
            } catch {
                request.reportImageResult(filename, outcome: .warning, message: "Skipped: \(error.localizedDescription)")
                continue
            }

            if let match = uploadCache.findMatch(for: fingerprint, threshold: sensitivity.threshold) {
                request.reportProgress("Skipping \(filename): perceptual match with \(match.filename)")
                request.reportImageResult(filename, outcome: .skip)
                continue
            }

            // 2. Check if ignored
            let imageState = request.state[filename]
            let ns = imageState.dependency(Self.pluginNamespace)

            if ns.strings(ProjectField.isIgnored)?.first == "true" {
                request.reportImageResult(filename, outcome: .warning, message: "Ignored: Not emailed")
                continue
            }

            // 3. Read state fields
            let recipient = ns.strings(ProjectField.recipient)?.first
            let subject = ns.strings(ProjectField.subject)?.first
            let body = ns.strings(ProjectField.body)?.first ?? ""

            // 4. Validate required fields
            guard let recipient, !recipient.isEmpty else {
                request.reportImageResult(filename, outcome: .failure, message: "Missing recipient")
                continue
            }
            guard let subject, !subject.isEmpty else {
                request.reportImageResult(filename, outcome: .failure, message: "Missing subject")
                continue
            }

            // 5. Dry run
            if request.dryRun {
                request.reportProgress("[dry-run] \(filename)")
                request.reportProgress("  To: \(recipient)")
                request.reportProgress("  Subject: \(subject)")
                if !body.isEmpty {
                    let preview = body.count > 80 ? "\(body.prefix(80))..." : body
                    request.reportProgress("  Body: \(preview)")
                }
                request.reportImageResult(filename, outcome: .success)
                uploadCache.add(hash: fingerprint.hash, filename: filename, editorURL: "(dry-run)")
                continue
            }

            // 6. Send email
            do {
                try emailSender.send(
                    recipient: recipient,
                    subject: subject,
                    body: body,
                    attachmentPath: imageURL.path,
                    attachmentFilename: filename
                )
            } catch {
                request.reportImageResult(filename, outcome: .failure, message: "Email send failed: \(error.localizedDescription)")
                continue
            }

            // 7. Update cache
            uploadCache.add(hash: fingerprint.hash, filename: filename, editorURL: "sent")
            try uploadCache.save()

            // 8. Report result
            request.reportProgress("\(filename) -> sent to \(recipient)")
            request.reportImageResult(filename, outcome: .success)
        }

        return .ok
    }
}
```

Note: `JSONValue.stringValue` and `JSONValue.intValue` are already provided by PiqleyCore — no extensions needed.

- [ ] **Step 2: Create main.swift**

Create `plugins/photo.quigs.365-project-publisher/Sources/365-project-publisher/main.swift`:

```swift
await Plugin().run()
```

- [ ] **Step 3: Commit**

```
feat(365): add Plugin handler and main entry point

Publish flow: fingerprint → dedup check → read state fields → validate
recipient/subject → send email via SMTP → update cache → report result.
Supports dry-run mode and is_ignored field.
```

### Task 7: Create Package.swift and verify build

**Files:**
- Create: `plugins/photo.quigs.365-project-publisher/Package.swift`

- [ ] **Step 1: Create Package.swift**

Create `plugins/photo.quigs.365-project-publisher/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "365-project-publisher",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/josephquigley/piqley-plugin-sdk",
            .upToNextMajor(from: "0.14.2")
        ),
        .package(
            url: "https://github.com/Kitura/Swift-SMTP.git",
            .upToNextMajor(from: "6.0.0")
        ),
    ],
    targets: [
        .target(
            name: "PluginHooks",
            dependencies: [
                .product(name: "PiqleyPluginSDK", package: "piqley-plugin-sdk"),
            ],
            path: "Sources/PluginHooks"
        ),
        .executableTarget(
            name: "365-project-publisher",
            dependencies: [
                "PluginHooks",
                .product(name: "Fingerprinting", package: "piqley-plugin-sdk"),
                .product(name: "SwiftSMTP", package: "Swift-SMTP"),
            ],
            path: "Sources/365-project-publisher"
        ),
        .executableTarget(
            name: "piqley-manifest-gen",
            dependencies: ["PluginHooks"],
            path: "Sources/ManifestGen"
        ),
    ]
)
```

- [ ] **Step 2: Build the plugin**

Run from `plugins/photo.quigs.365-project-publisher/`:
```bash
swift build
```

Expected: Build succeeds with all three targets (PluginHooks, 365-project-publisher, piqley-manifest-gen).

- [ ] **Step 3: Run manifest generation**

```bash
mkdir -p /tmp/365-manifest-test
swift run piqley-manifest-gen /tmp/365-manifest-test
```

Expected: Creates `stage-publish.json`, `config-entries.json`, `consumed-fields.json`, and `fields.json` in the output directory.

- [ ] **Step 4: Commit**

```
feat(365): add Package.swift, verify build and manifest generation

Plugin depends on piqley-plugin-sdk (PiqleyPluginSDK + Fingerprinting)
and Kitura/Swift-SMTP. All three targets build successfully.
```
