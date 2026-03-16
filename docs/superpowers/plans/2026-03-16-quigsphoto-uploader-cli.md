# quigsphoto-uploader CLI Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Swift CLI tool that processes Lightroom-exported photos, uploads them to Ghost CMS with scheduling, and emails 365 Project photos — invoked by macOS Hazel.

**Architecture:** Monolithic CLI with `process` and `setup` subcommands. Protocol abstractions (`SecretStore`, `ImageProcessor`, `MetadataReader`) for platform portability. Two-tier dedup (local JSONL cache + Ghost API fallback). Config-driven via `~/.config/quigsphoto-uploader/config.json`.

**Tech Stack:** Swift 5.9+, Swift Package Manager, swift-argument-parser, swift-log, SwiftSMTP (or similar), CoreGraphics/CoreImage (behind protocols), macOS Security framework (behind protocol).

**Spec:** `docs/superpowers/specs/2026-03-16-quigsphoto-uploader-cli-design.md`

---

## File Map

```
Sources/quigsphoto-uploader/
├── main.swift                              — Entry point, registers commands
├── Constants.swift                         — AppConstants enum with centralized name strings
├── CLI/
│   ├── ProcessCommand.swift                — `process` subcommand, orchestrates pipeline
│   └── SetupCommand.swift                  — `setup` subcommand, interactive config creation
├── Config/
│   └── Config.swift                        — Codable config model, load/save
├── Secrets/
│   ├── SecretStore.swift                   — Protocol: get/set secrets by key
│   └── KeychainSecretStore.swift           — macOS Keychain implementation
├── ImageProcessing/
│   ├── ImageScanner.swift                  — Scan folder for images, sort by date taken
│   ├── ImageMetadata.swift                 — Metadata model (title, desc, keywords, date)
│   ├── MetadataReader.swift                — Protocol: read EXIF/IPTC from image file
│   ├── CGImageMetadataReader.swift         — macOS CGImageSource implementation
│   ├── ImageProcessor.swift                — Protocol: resize/encode image
│   └── CoreGraphicsImageProcessor.swift    — macOS CoreGraphics implementation
├── Ghost/
│   ├── GhostClient.swift                   — HTTP client, JWT auth, API methods
│   ├── GhostScheduler.swift                — Query queues, pick schedule dates/times
│   ├── GhostDeduplicator.swift             — Two-tier dedup (cache + API)
│   ├── LexicalBuilder.swift                — Build Lexical JSON for post bodies
│   └── GhostModels.swift                   — Codable models for Ghost API responses
│   NOTE: Upload orchestration lives in ProcessCommand for v1 simplicity.
│         Extract to GhostUploader.swift if ProcessCommand grows too large.
├── Email/
│   └── EmailSender.swift                   — SMTP email sending for 365 Project
├── Logging/
│   ├── UploadLog.swift                     — Read/append upload-log.jsonl
│   └── EmailLog.swift                      — Read/append email-log.jsonl, seed from Ghost
├── Results/
│   └── ResultsWriter.swift                 — Write result files (text or JSON)
└── ProcessLock.swift                       — Advisory file lock for single-instance

Tests/quigsphoto-uploaderTests/
├── ConfigTests.swift
├── ImageScannerTests.swift
├── MetadataReaderTests.swift
├── ImageProcessorTests.swift
├── GhostClientTests.swift
├── GhostSchedulerTests.swift
├── GhostDeduplicatorTests.swift
├── LexicalBuilderTests.swift
├── UploadLogTests.swift
├── EmailLogTests.swift
├── ResultsWriterTests.swift
└── Fixtures/
    ├── sample.jpg                          — Small test JPEG with EXIF/IPTC metadata
    ├── sample-no-title.jpg                 — JPEG missing title
    ├── sample-365.jpg                      — JPEG with "365 Project" keyword
    └── sample-hierarchical-tags.jpg        — JPEG with hierarchical IPTC keywords
```

---

## Chunk 1: Project Foundation

### Task 1: Swift Package Setup

**Files:**
- Create: `Package.swift`
- Create: `Sources/quigsphoto-uploader/main.swift`

- [ ] **Step 1: Initialize Swift package**

```bash
cd /Users/wash/Developer/tools/quigsphoto-uploader
swift package init --type executable --name quigsphoto-uploader
```

- [ ] **Step 2: Edit Package.swift with dependencies**

Replace the generated `Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "quigsphoto-uploader",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/Kitura/Swift-SMTP.git", from: "6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "quigsphoto-uploader",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSMTP", package: "Swift-SMTP"),
            ]
        ),
        .testTarget(
            name: "quigsphoto-uploaderTests",
            dependencies: ["quigsphoto-uploader"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 3: Write minimal main.swift**

```swift
import ArgumentParser

@main
struct QuigsphotoUploader: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quigsphoto-uploader",
        abstract: "Process and publish photos to Ghost CMS",
        subcommands: [ProcessCommand.self, SetupCommand.self]
    )
}
```

- [ ] **Step 4: Create stub subcommands so it compiles**

Create `Sources/quigsphoto-uploader/CLI/ProcessCommand.swift`:
```swift
import ArgumentParser

struct ProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process all images in a folder and publish to Ghost CMS"
    )

    @Argument(help: "Path to folder containing exported images")
    var folderPath: String

    @Flag(help: "Preview actions without uploading or emailing")
    var dryRun = false

    @Flag(help: "Include successful images in result output")
    var verboseResults = false

    @Flag(help: "Write a single JSON results file instead of individual text files")
    var jsonResults = false

    @Option(help: "Directory to write result files to (default: input folder)")
    var resultsDir: String?

    func run() throws {
        print("Processing folder: \(folderPath)")
    }
}
```

Create `Sources/quigsphoto-uploader/CLI/SetupCommand.swift`:
```swift
import ArgumentParser

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup — configure Ghost, SMTP, and processing settings"
    )

    func run() throws {
        print("Running setup...")
    }
}
```

- [ ] **Step 5: Verify it builds and runs**

```bash
swift build
swift run quigsphoto-uploader --help
swift run quigsphoto-uploader process --help
swift run quigsphoto-uploader setup --help
```

Expected: clean build, help output shows both subcommands with all flags.

- [ ] **Step 6: Commit**

```bash
git init
git add Package.swift Sources/ Tests/ .agents/ docs/
git commit -m "feat: initialize Swift package with CLI skeleton and subcommands"
```

---

### Task 1.5: App Constants

**Files:**
- Create: `Sources/quigsphoto-uploader/Constants.swift`

- [ ] **Step 1: Create Constants.swift with all name-related magic strings**

```swift
import Foundation

enum AppConstants {
    static let binaryName = "quigsphoto-uploader"
    static let configDirectoryName = "quigsphoto-uploader"
    static let keychainServicePrefix = "quigsphoto-uploader"
    static let resultFilePrefix = ".quigsphoto-uploader"
    static let tempDirectoryName = "quigsphoto-uploader"
    static let loggerPrefix = "quigsphoto-uploader"
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
swift build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/quigsphoto-uploader/Constants.swift
git commit -m "feat: add AppConstants enum for centralized name-related strings"
```

---

### Task 2: Config Model

**Files:**
- Create: `Sources/quigsphoto-uploader/Config/Config.swift`
- Create: `Tests/quigsphoto-uploaderTests/ConfigTests.swift`

- [ ] **Step 1: Write Config tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class ConfigTests: XCTestCase {
    func testDecodeFullConfig() throws {
        let json = """
        {
            "ghost": {
                "url": "https://quigs.photo",
                "schedulingWindow": {
                    "start": "08:00",
                    "end": "10:00",
                    "timezone": "America/New_York"
                }
            },
            "processing": {
                "maxLongEdge": 2000,
                "jpegQuality": 80
            },
            "project365": {
                "keyword": "365 Project",
                "referenceDate": "2025-12-25",
                "emailTo": "user@365project.example"
            },
            "smtp": {
                "host": "smtp.example.com",
                "port": 587,
                "username": "user@example.com",
                "from": "user@example.com"
            },
            "tagBlocklist": ["PersonalOnly", "Draft"]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.ghost.url, "https://quigs.photo")
        XCTAssertEqual(config.ghost.schedulingWindow.start, "08:00")
        XCTAssertEqual(config.ghost.schedulingWindow.timezone, "America/New_York")
        XCTAssertEqual(config.processing.maxLongEdge, 2000)
        XCTAssertEqual(config.processing.jpegQuality, 80)
        XCTAssertEqual(config.project365.keyword, "365 Project")
        XCTAssertEqual(config.project365.referenceDate, "2025-12-25")
        XCTAssertEqual(config.smtp.from, "user@example.com")
        XCTAssertEqual(config.tagBlocklist, ["PersonalOnly", "Draft"])
    }

    func testConfigRoundTrip() throws {
        let config = AppConfig(
            ghost: .init(
                url: "https://example.com",
                schedulingWindow: .init(start: "09:00", end: "11:00", timezone: "UTC")
            ),
            processing: .init(maxLongEdge: 1500, jpegQuality: 75),
            project365: .init(keyword: "365 Project", referenceDate: "2025-12-25", emailTo: "test@test.com"),
            smtp: .init(host: "smtp.test.com", port: 465, username: "u", from: "u@test.com"),
            tagBlocklist: ["WIP"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(config.ghost.url, decoded.ghost.url)
        XCTAssertEqual(config.processing.maxLongEdge, decoded.processing.maxLongEdge)
    }

    func testLoadConfigFromFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configPath = tmpDir.appendingPathComponent("config.json")
        let config = AppConfig(
            ghost: .init(url: "https://test.ghost.io", schedulingWindow: .init(start: "08:00", end: "10:00", timezone: "UTC")),
            processing: .init(maxLongEdge: 2000, jpegQuality: 80),
            project365: .init(keyword: "365 Project", referenceDate: "2025-12-25", emailTo: "t@t.com"),
            smtp: .init(host: "smtp.t.com", port: 587, username: "u", from: "u@t.com"),
            tagBlocklist: []
        )
        let data = try JSONEncoder().encode(config)
        try data.write(to: configPath)

        let loaded = try AppConfig.load(from: configPath.path)
        XCTAssertEqual(loaded.ghost.url, "https://test.ghost.io")
    }

    func testLoadConfigMissingFileThrows() {
        XCTAssertThrowsError(try AppConfig.load(from: "/nonexistent/config.json"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ConfigTests
```

Expected: compilation error — `AppConfig` not defined.

- [ ] **Step 3: Implement Config.swift**

```swift
import Foundation

struct AppConfig: Codable, Equatable {
    var ghost: GhostConfig
    var processing: ProcessingConfig
    var project365: Project365Config
    var smtp: SMTPConfig
    var tagBlocklist: [String]

    struct GhostConfig: Codable, Equatable {
        var url: String
        var schedulingWindow: SchedulingWindow

        struct SchedulingWindow: Codable, Equatable {
            var start: String
            var end: String
            var timezone: String
        }
    }

    struct ProcessingConfig: Codable, Equatable {
        var maxLongEdge: Int
        var jpegQuality: Int
    }

    struct Project365Config: Codable, Equatable {
        var keyword: String
        var referenceDate: String
        var emailTo: String
    }

    struct SMTPConfig: Codable, Equatable {
        var host: String
        var port: Int
        var username: String
        var from: String
    }

    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/\(AppConstants.configDirectoryName)")

    static let configPath = configDirectory.appendingPathComponent("config.json")

    static func load(from path: String) throws -> AppConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ConfigTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Config/ Tests/quigsphoto-uploaderTests/ConfigTests.swift
git commit -m "feat: add Config model with load/save and tests"
```

---

### Task 3: SecretStore Protocol & Keychain Implementation

**Files:**
- Create: `Sources/quigsphoto-uploader/Secrets/SecretStore.swift`
- Create: `Sources/quigsphoto-uploader/Secrets/KeychainSecretStore.swift`

- [ ] **Step 1: Write SecretStore protocol**

```swift
import Foundation

protocol SecretStore {
    func get(key: String) throws -> String
    func set(key: String, value: String) throws
    func delete(key: String) throws
}

enum SecretStoreError: Error, LocalizedError {
    case notFound(key: String)
    case unexpectedError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound(let key):
            return "Secret not found for key: \(key)"
        case .unexpectedError(let status):
            return "Keychain error: \(status)"
        }
    }
}
```

- [ ] **Step 2: Implement KeychainSecretStore**

```swift
import Foundation
import Security

struct KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = AppConstants.keychainServicePrefix) {
        self.service = service
    }

    func get(key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound {
                throw SecretStoreError.notFound(key: key)
            }
            throw SecretStoreError.unexpectedError(status: status)
        }
        return value
    }

    func set(key: String, value: String) throws {
        // Delete existing if present
        try? delete(key: key)

        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedError(status: status)
        }
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedError(status: status)
        }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

```bash
swift build
```

Expected: clean build. (Keychain tests require actual Keychain access so we skip automated tests for this — manual verification via `setup` command later.)

- [ ] **Step 4: Commit**

```bash
git add Sources/quigsphoto-uploader/Secrets/
git commit -m "feat: add SecretStore protocol and Keychain implementation"
```

---

### Task 4: Process Lock

**Files:**
- Create: `Sources/quigsphoto-uploader/ProcessLock.swift`
- Create: `Tests/quigsphoto-uploaderTests/ProcessLockTests.swift`

- [ ] **Step 1: Write ProcessLock tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class ProcessLockTests: XCTestCase {
    func testAcquireAndReleaseLock() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock = try ProcessLock(path: lockPath)
        lock.release()
    }

    func testDoubleAcquireFails() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockPath = tmpDir.appendingPathComponent("test.lock").path
        let lock1 = try ProcessLock(path: lockPath)
        XCTAssertThrowsError(try ProcessLock(path: lockPath))
        lock1.release()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ProcessLockTests
```

Expected: compilation error.

- [ ] **Step 3: Implement ProcessLock**

```swift
import Foundation

final class ProcessLock {
    private var fileDescriptor: Int32
    private let path: String
    private var released = false

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw ProcessLockError.cannotOpenLockFile(path: path)
        }
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fd)
            throw ProcessLockError.alreadyRunning
        }
        self.fileDescriptor = fd
        self.path = path
    }

    func release() {
        guard !released else { return }
        released = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    deinit {
        release()
    }
}

enum ProcessLockError: Error, LocalizedError {
    case cannotOpenLockFile(path: String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .cannotOpenLockFile(let path):
            return "Cannot open lock file: \(path)"
        case .alreadyRunning:
            return "Another instance of \(AppConstants.binaryName) is already running"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ProcessLockTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/ProcessLock.swift Tests/quigsphoto-uploaderTests/ProcessLockTests.swift
git commit -m "feat: add advisory file lock for single-instance enforcement"
```

---

### Task 5: JSONL Log Files (Upload Log & Email Log)

**Files:**
- Create: `Sources/quigsphoto-uploader/Logging/UploadLog.swift`
- Create: `Sources/quigsphoto-uploader/Logging/EmailLog.swift`
- Create: `Tests/quigsphoto-uploaderTests/UploadLogTests.swift`
- Create: `Tests/quigsphoto-uploaderTests/EmailLogTests.swift`

- [ ] **Step 1: Write UploadLog tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class UploadLogTests: XCTestCase {
    var tmpDir: URL!
    var logPath: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logPath = tmpDir.appendingPathComponent("upload-log.jsonl").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testAppendAndContains() throws {
        let log = UploadLog(path: logPath)
        let entry = UploadLogEntry(
            filename: "IMG_001.jpg",
            ghostUrl: "https://quigs.photo/p/test",
            postId: "abc123",
            timestamp: Date()
        )
        try log.append(entry)
        XCTAssertTrue(try log.contains(filename: "IMG_001.jpg"))
        XCTAssertFalse(try log.contains(filename: "IMG_002.jpg"))
    }

    func testEmptyLogContainsNothing() throws {
        let log = UploadLog(path: logPath)
        XCTAssertFalse(try log.contains(filename: "anything.jpg"))
    }

    func testMultipleAppends() throws {
        let log = UploadLog(path: logPath)
        for i in 1...5 {
            let entry = UploadLogEntry(
                filename: "IMG_\(i).jpg",
                ghostUrl: "https://quigs.photo/p/\(i)",
                postId: "id\(i)",
                timestamp: Date()
            )
            try log.append(entry)
        }
        XCTAssertTrue(try log.contains(filename: "IMG_3.jpg"))
        XCTAssertFalse(try log.contains(filename: "IMG_6.jpg"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter UploadLogTests
```

Expected: compilation error.

- [ ] **Step 3: Implement UploadLog**

```swift
import Foundation

struct UploadLogEntry: Codable {
    let filename: String
    let ghostUrl: String
    let postId: String
    let timestamp: Date
}

struct UploadLog {
    let path: String

    func contains(filename: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(UploadLogEntry.self, from: lineData) else { continue }
            if entry.filename == filename { return true }
        }
        return false
    }

    func append(_ entry: UploadLogEntry) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(contentsOf: "\n".utf8)

        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            throw UploadLogError.cannotOpenFile(path: path)
        }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            _ = write(fd, buffer.baseAddress!, buffer.count)
        }
    }
}

enum UploadLogError: Error, LocalizedError {
    case cannotOpenFile(path: String)
    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Cannot open upload log: \(path)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter UploadLogTests
```

Expected: all pass.

- [ ] **Step 5: Write EmailLog tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class EmailLogTests: XCTestCase {
    var tmpDir: URL!
    var logPath: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logPath = tmpDir.appendingPathComponent("email-log.jsonl").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testAppendAndContains() throws {
        let log = EmailLog(path: logPath)
        let entry = EmailLogEntry(
            filename: "IMG_001.jpg",
            emailTo: "user@365project.example",
            subject: "Test Photo",
            timestamp: Date()
        )
        try log.append(entry)
        XCTAssertTrue(try log.contains(filename: "IMG_001.jpg"))
        XCTAssertFalse(try log.contains(filename: "IMG_002.jpg"))
    }

    func testNonExistentLogReturnsFalse() throws {
        let log = EmailLog(path: logPath)
        XCTAssertFalse(try log.contains(filename: "anything.jpg"))
    }

    func testFileExistsProperty() throws {
        let log = EmailLog(path: logPath)
        XCTAssertFalse(log.fileExists)
        let entry = EmailLogEntry(
            filename: "IMG_001.jpg",
            emailTo: "user@test.com",
            subject: "Test",
            timestamp: Date()
        )
        try log.append(entry)
        XCTAssertTrue(log.fileExists)
    }
}
```

- [ ] **Step 6: Implement EmailLog**

```swift
import Foundation

struct EmailLogEntry: Codable {
    let filename: String
    let emailTo: String
    let subject: String
    let timestamp: Date
}

struct EmailLog {
    let path: String

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func contains(filename: String) throws -> Bool {
        guard fileExists else { return false }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(EmailLogEntry.self, from: lineData) else { continue }
            if entry.filename == filename { return true }
        }
        return false
    }

    func append(_ entry: EmailLogEntry) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(contentsOf: "\n".utf8)

        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            throw EmailLogError.cannotOpenFile(path: path)
        }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            _ = write(fd, buffer.baseAddress!, buffer.count)
        }
    }
}

enum EmailLogError: Error, LocalizedError {
    case cannotOpenFile(path: String)
    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Cannot open email log: \(path)"
        }
    }
}
```

- [ ] **Step 7: Run all log tests**

```bash
swift test --filter "UploadLogTests|EmailLogTests"
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/quigsphoto-uploader/Logging/ Tests/quigsphoto-uploaderTests/UploadLogTests.swift Tests/quigsphoto-uploaderTests/EmailLogTests.swift
git commit -m "feat: add JSONL upload and email logs with atomic append"
```

---

### Task 6: Results Writer

**Files:**
- Create: `Sources/quigsphoto-uploader/Results/ResultsWriter.swift`
- Create: `Tests/quigsphoto-uploaderTests/ResultsWriterTests.swift`

- [ ] **Step 1: Write ResultsWriter tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class ResultsWriterTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testWriteTextFiles() throws {
        let results = ProcessingResults(
            successes: ["a.jpg", "b.jpg"],
            failures: ["c.jpg"],
            duplicates: ["d.jpg"]
        )
        try ResultsWriter.writeText(results: results, to: tmpDir.path, verbose: false)

        let failurePath = tmpDir.appendingPathComponent(".quigsphoto-uploader-failure.txt").path
        let dupPath = tmpDir.appendingPathComponent(".quigsphoto-uploader-duplicate.txt").path
        let successPath = tmpDir.appendingPathComponent(".quigsphoto-uploader-success.txt").path

        XCTAssertTrue(FileManager.default.fileExists(atPath: failurePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dupPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: successPath))

        let failureContent = try String(contentsOfFile: failurePath, encoding: .utf8)
        XCTAssertEqual(failureContent.trimmingCharacters(in: .whitespacesAndNewlines), "c.jpg")
    }

    func testWriteTextFilesVerbose() throws {
        let results = ProcessingResults(successes: ["a.jpg"], failures: [], duplicates: [])
        try ResultsWriter.writeText(results: results, to: tmpDir.path, verbose: true)

        let successPath = tmpDir.appendingPathComponent(".quigsphoto-uploader-success.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: successPath))
    }

    func testEmptyArraysProduceNoFiles() throws {
        let results = ProcessingResults(successes: [], failures: [], duplicates: [])
        try ResultsWriter.writeText(results: results, to: tmpDir.path, verbose: false)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testWriteJSON() throws {
        let results = ProcessingResults(
            successes: ["a.jpg"],
            failures: ["b.jpg"],
            duplicates: ["c.jpg"]
        )
        try ResultsWriter.writeJSON(results: results, to: tmpDir.path, verbose: true)

        let jsonPath = tmpDir.appendingPathComponent(".quigsphoto-uploader-results.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath))

        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoded = try JSONDecoder().decode(JSONResults.self, from: data)
        XCTAssertEqual(decoded.failures, ["b.jpg"])
        XCTAssertEqual(decoded.duplicates, ["c.jpg"])
        XCTAssertEqual(decoded.successes, ["a.jpg"])
    }

    func testWriteJSONNonVerboseOmitsSuccesses() throws {
        let results = ProcessingResults(successes: ["a.jpg"], failures: [], duplicates: [])
        try ResultsWriter.writeJSON(results: results, to: tmpDir.path, verbose: false)

        let jsonPath = tmpDir.appendingPathComponent(".quigsphoto-uploader-results.json").path
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoded = try JSONDecoder().decode(JSONResults.self, from: data)
        XCTAssertTrue(decoded.successes.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ResultsWriterTests
```

Expected: compilation error.

- [ ] **Step 3: Implement ResultsWriter**

```swift
import Foundation

struct ProcessingResults {
    var successes: [String] = []
    var failures: [String] = []
    var duplicates: [String] = []
    var drafts: [String] = []
    var scheduled: [String] = []
}

struct JSONResults: Codable {
    let failures: [String]
    let duplicates: [String]
    let successes: [String]
}

enum ResultsWriter {
    static func writeText(results: ProcessingResults, to directory: String, verbose: Bool) throws {
        if !results.failures.isEmpty {
            let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-failure.txt")
            try results.failures.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if !results.duplicates.isEmpty {
            let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-duplicate.txt")
            try results.duplicates.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if verbose && !results.successes.isEmpty {
            let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-success.txt")
            try results.successes.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func writeJSON(results: ProcessingResults, to directory: String, verbose: Bool) throws {
        let jsonResults = JSONResults(
            failures: results.failures,
            duplicates: results.duplicates,
            successes: verbose ? results.successes : []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(jsonResults)
        let path = (directory as NSString).appendingPathComponent("\(AppConstants.resultFilePrefix)-results.json")
        try data.write(to: URL(fileURLWithPath: path))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ResultsWriterTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Results/ Tests/quigsphoto-uploaderTests/ResultsWriterTests.swift
git commit -m "feat: add results writer for text and JSON output"
```

---

## Chunk 2: Image Processing

### Task 7: Test Fixtures

**Files:**
- Create: `Tests/quigsphoto-uploaderTests/Fixtures/` (test images)

- [ ] **Step 1: Create test fixture images programmatically**

We need test JPEGs with specific EXIF/IPTC metadata. Create a helper script that generates them using `sips` and `exiftool` (if available), or we embed minimal JPEG data in a test helper.

Create `Tests/quigsphoto-uploaderTests/TestHelpers.swift`:

```swift
import Foundation
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
        dateTimeOriginal: String? = "2026:01:15 10:30:00"
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw TestFixtureError.cannotCreateContext
        }

        // Fill with a color so it's a valid image
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw TestFixtureError.cannotCreateImage
        }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) else {
            throw TestFixtureError.cannotCreateDestination
        }

        var properties: [String: Any] = [:]
        var exifDict: [String: Any] = [:]
        var iptcDict: [String: Any] = [:]

        if let dateTimeOriginal {
            exifDict[kCGImagePropertyExifDateTimeOriginal as String] = dateTimeOriginal
        }
        if let title {
            iptcDict[kCGImagePropertyIPTCObjectName as String] = title
        }
        if let description {
            iptcDict[kCGImagePropertyIPTCCaptionAbstract as String] = description
        }
        if let keywords {
            iptcDict[kCGImagePropertyIPTCKeywords as String] = keywords
        }

        if !exifDict.isEmpty {
            properties[kCGImagePropertyExifDictionary as String] = exifDict
        }
        if !iptcDict.isEmpty {
            properties[kCGImagePropertyIPTCDictionary as String] = iptcDict
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw TestFixtureError.cannotFinalize
        }
    }
}

enum TestFixtureError: Error {
    case cannotCreateContext
    case cannotCreateImage
    case cannotCreateDestination
    case cannotFinalize
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
swift build --build-tests
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Tests/quigsphoto-uploaderTests/TestHelpers.swift
git commit -m "feat: add test fixture helper for creating JPEG images with metadata"
```

---

### Task 8: MetadataReader Protocol & CGImage Implementation

**Files:**
- Create: `Sources/quigsphoto-uploader/ImageProcessing/ImageMetadata.swift`
- Create: `Sources/quigsphoto-uploader/ImageProcessing/MetadataReader.swift`
- Create: `Sources/quigsphoto-uploader/ImageProcessing/CGImageMetadataReader.swift`
- Create: `Tests/quigsphoto-uploaderTests/MetadataReaderTests.swift`

- [ ] **Step 1: Write ImageMetadata model**

```swift
import Foundation

struct ImageMetadata {
    let title: String?
    let description: String?
    let keywords: [String]
    let dateTimeOriginal: Date?
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?

    /// Extract leaf node from hierarchical keyword (e.g., "Location > USA > Nashville" → "Nashville")
    static func leafKeyword(_ keyword: String) -> String {
        let parts = keyword.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.last ?? keyword
    }

    /// Filter keywords: extract leaf nodes, remove blocklisted
    static func processKeywords(_ raw: [String], blocklist: [String]) -> [String] {
        raw.map { leafKeyword($0) }
           .filter { !blocklist.contains($0) }
    }

    /// Check if this image is tagged for 365 Project
    func is365Project(keyword: String) -> Bool {
        let leaves = keywords.map { ImageMetadata.leafKeyword($0) }
        return leaves.contains(keyword)
    }
}
```

- [ ] **Step 2: Write MetadataReader protocol**

```swift
import Foundation

protocol MetadataReader {
    func read(from path: String) throws -> ImageMetadata
}
```

- [ ] **Step 3: Write MetadataReader tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class MetadataReaderTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testReadMetadataWithAllFields() throws {
        let path = tmpDir.appendingPathComponent("test.jpg").path
        try TestFixtures.createTestJPEG(
            at: path,
            title: "Sunset at the Beach",
            description: "A beautiful sunset",
            keywords: ["Landscape", "365 Project", "Nature"],
            dateTimeOriginal: "2026:01:15 10:30:00"
        )

        let reader = CGImageMetadataReader()
        let metadata = try reader.read(from: path)

        XCTAssertEqual(metadata.title, "Sunset at the Beach")
        XCTAssertEqual(metadata.description, "A beautiful sunset")
        XCTAssertTrue(metadata.keywords.contains("365 Project"))
        XCTAssertTrue(metadata.keywords.contains("Landscape"))
        XCTAssertNotNil(metadata.dateTimeOriginal)
    }

    func testReadMetadataMissingTitle() throws {
        let path = tmpDir.appendingPathComponent("notitle.jpg").path
        try TestFixtures.createTestJPEG(at: path, title: nil, description: nil, keywords: nil)

        let reader = CGImageMetadataReader()
        let metadata = try reader.read(from: path)

        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.description)
    }

    func testLeafKeywordExtraction() {
        XCTAssertEqual(ImageMetadata.leafKeyword("Location > USA > Nashville"), "Nashville")
        XCTAssertEqual(ImageMetadata.leafKeyword("SimpleTag"), "SimpleTag")
        XCTAssertEqual(ImageMetadata.leafKeyword("A > B"), "B")
    }

    func testProcessKeywordsWithBlocklist() {
        let raw = ["Location > USA > Nashville", "365 Project", "WIP", "Nature"]
        let result = ImageMetadata.processKeywords(raw, blocklist: ["WIP"])
        XCTAssertEqual(result, ["Nashville", "365 Project", "Nature"])
    }

    func testIs365Project() throws {
        let path = tmpDir.appendingPathComponent("365.jpg").path
        try TestFixtures.createTestJPEG(at: path, keywords: ["365 Project", "Nature"])

        let reader = CGImageMetadataReader()
        let metadata = try reader.read(from: path)
        XCTAssertTrue(metadata.is365Project(keyword: "365 Project"))
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
swift test --filter MetadataReaderTests
```

Expected: compilation error — `CGImageMetadataReader` not defined.

- [ ] **Step 5: Implement CGImageMetadataReader**

```swift
import Foundation
import CoreGraphics
import ImageIO

struct CGImageMetadataReader: MetadataReader {
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func read(from path: String) throws -> ImageMetadata {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else {
            throw MetadataReaderError.cannotOpenFile(path: path)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw MetadataReaderError.cannotReadProperties(path: path)
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

        let title = iptc[kCGImagePropertyIPTCObjectName as String] as? String
        let description = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String
        let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []

        var dateTimeOriginal: Date?
        if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            dateTimeOriginal = Self.exifDateFormatter.date(from: dateStr)
        }

        let cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
        let cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
        let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String

        return ImageMetadata(
            title: title,
            description: description,
            keywords: keywords,
            dateTimeOriginal: dateTimeOriginal,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            lensModel: lensModel
        )
    }
}

enum MetadataReaderError: Error, LocalizedError {
    case cannotOpenFile(path: String)
    case cannotReadProperties(path: String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Cannot open image file: \(path)"
        case .cannotReadProperties(let path): return "Cannot read EXIF/IPTC from: \(path)"
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
swift test --filter MetadataReaderTests
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/quigsphoto-uploader/ImageProcessing/ImageMetadata.swift Sources/quigsphoto-uploader/ImageProcessing/MetadataReader.swift Sources/quigsphoto-uploader/ImageProcessing/CGImageMetadataReader.swift Tests/quigsphoto-uploaderTests/MetadataReaderTests.swift
git commit -m "feat: add MetadataReader protocol and CGImage implementation with EXIF/IPTC parsing"
```

---

### Task 9: ImageScanner (Scan & Sort)

**Files:**
- Create: `Sources/quigsphoto-uploader/ImageProcessing/ImageScanner.swift`
- Create: `Tests/quigsphoto-uploaderTests/ImageScannerTests.swift`

- [ ] **Step 1: Write ImageScanner tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class ImageScannerTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testFindsJPEGFiles() throws {
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("a.jpg").path)
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("b.JPEG").path)
        try "not an image".write(to: tmpDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertEqual(files.count, 2)
    }

    func testSortsByDateTaken() throws {
        try TestFixtures.createTestJPEG(
            at: tmpDir.appendingPathComponent("newer.jpg").path,
            dateTimeOriginal: "2026:03:15 10:00:00"
        )
        try TestFixtures.createTestJPEG(
            at: tmpDir.appendingPathComponent("older.jpg").path,
            dateTimeOriginal: "2026:01:01 08:00:00"
        )

        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].path.hasSuffix("older.jpg"))
        XCTAssertTrue(files[1].path.hasSuffix("newer.jpg"))
    }

    func testMissingDateSortsToEnd() throws {
        try TestFixtures.createTestJPEG(
            at: tmpDir.appendingPathComponent("dated.jpg").path,
            dateTimeOriginal: "2026:01:01 08:00:00"
        )
        try TestFixtures.createTestJPEG(
            at: tmpDir.appendingPathComponent("undated.jpg").path,
            dateTimeOriginal: nil
        )

        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].path.hasSuffix("dated.jpg"))
        XCTAssertTrue(files[1].path.hasSuffix("undated.jpg"))
    }

    func testFindsJXLFiles() throws {
        // Create a dummy .jxl file (won't have valid metadata but should be found)
        try Data().write(to: tmpDir.appendingPathComponent("photo.jxl"))
        try TestFixtures.createTestJPEG(at: tmpDir.appendingPathComponent("photo.jpg").path)

        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        // .jxl file will be found but may fail metadata read — that's expected
        // At minimum the .jpg is found
        XCTAssertTrue(files.count >= 1)
    }

    func testEmptyFolder() throws {
        let scanner = ImageScanner(metadataReader: CGImageMetadataReader())
        let files = try scanner.scan(folder: tmpDir.path)
        XCTAssertTrue(files.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ImageScannerTests
```

Expected: compilation error.

- [ ] **Step 3: Implement ImageScanner**

```swift
import Foundation
import Logging

struct ScannedImage {
    let path: String
    let filename: String
    let metadata: ImageMetadata
}

struct ImageScanner {
    private static let supportedExtensions: Set<String> = ["jpg", "jpeg", "jxl"]
    private let metadataReader: MetadataReader
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).scanner")

    init(metadataReader: MetadataReader) {
        self.metadataReader = metadataReader
    }

    func scan(folder: String) throws -> [ScannedImage] {
        let url = URL(fileURLWithPath: folder)
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let imageFiles = contents.filter {
            Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }

        var scanned: [ScannedImage] = []
        for file in imageFiles {
            do {
                let metadata = try metadataReader.read(from: file.path)
                scanned.append(ScannedImage(
                    path: file.path,
                    filename: file.lastPathComponent,
                    metadata: metadata
                ))
            } catch {
                logger.warning("Skipping \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return scanned.sorted { a, b in
            switch (a.metadata.dateTimeOriginal, b.metadata.dateTimeOriginal) {
            case let (dateA?, dateB?):
                return dateA < dateB
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return a.filename < b.filename
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ImageScannerTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/ImageProcessing/ImageScanner.swift Tests/quigsphoto-uploaderTests/ImageScannerTests.swift
git commit -m "feat: add ImageScanner — scan folder, read metadata, sort by date taken"
```

---

### Task 10: ImageProcessor Protocol & CoreGraphics Implementation

**Files:**
- Create: `Sources/quigsphoto-uploader/ImageProcessing/ImageProcessor.swift`
- Create: `Sources/quigsphoto-uploader/ImageProcessing/CoreGraphicsImageProcessor.swift`
- Create: `Tests/quigsphoto-uploaderTests/ImageProcessorTests.swift`

- [ ] **Step 1: Write ImageProcessor tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class ImageProcessorTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testResizeLandscapeImage() throws {
        let inputPath = tmpDir.appendingPathComponent("input.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, width: 4000, height: 3000)

        let processor = CoreGraphicsImageProcessor()
        try processor.process(
            inputPath: inputPath,
            outputPath: outputPath,
            maxLongEdge: 2000,
            jpegQuality: 80
        )

        // Verify output exists and is smaller
        let inputSize = try FileManager.default.attributesOfItem(atPath: inputPath)[.size] as! UInt64
        let outputSize = try FileManager.default.attributesOfItem(atPath: outputPath)[.size] as! UInt64
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(outputSize < inputSize)

        // Verify dimensions
        let reader = CGImageMetadataReader()
        let url = URL(fileURLWithPath: outputPath) as CFURL
        let source = CGImageSourceCreateWithURL(url, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let width = props[kCGImagePropertyPixelWidth as String] as! Int
        let height = props[kCGImagePropertyPixelHeight as String] as! Int
        XCTAssertEqual(width, 2000) // long edge
        XCTAssertEqual(height, 1500) // proportional
    }

    func testNoUpscale() throws {
        let inputPath = tmpDir.appendingPathComponent("small.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, width: 800, height: 600)

        let processor = CoreGraphicsImageProcessor()
        try processor.process(
            inputPath: inputPath,
            outputPath: outputPath,
            maxLongEdge: 2000,
            jpegQuality: 80
        )

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let width = props[kCGImagePropertyPixelWidth as String] as! Int
        XCTAssertEqual(width, 800) // not upscaled
    }

    func testGPSStripped() throws {
        let inputPath = tmpDir.appendingPathComponent("gps.jpg").path
        let outputPath = tmpDir.appendingPathComponent("output.jpg").path
        try TestFixtures.createTestJPEG(at: inputPath, title: "Keep This Title")

        let processor = CoreGraphicsImageProcessor()
        try processor.process(
            inputPath: inputPath,
            outputPath: outputPath,
            maxLongEdge: 2000,
            jpegQuality: 80
        )

        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ImageProcessorTests
```

Expected: compilation error.

- [ ] **Step 3: Write ImageProcessor protocol**

```swift
import Foundation

protocol ImageProcessor {
    func process(
        inputPath: String,
        outputPath: String,
        maxLongEdge: Int,
        jpegQuality: Int
    ) throws
}
```

- [ ] **Step 4: Implement CoreGraphicsImageProcessor**

```swift
import Foundation
import CoreGraphics
import ImageIO

struct CoreGraphicsImageProcessor: ImageProcessor {
    func process(
        inputPath: String,
        outputPath: String,
        maxLongEdge: Int,
        jpegQuality: Int
    ) throws {
        let inputURL = URL(fileURLWithPath: inputPath) as CFURL
        guard let source = CGImageSourceCreateWithURL(inputURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessorError.cannotReadImage(path: inputPath)
        }

        // Read original properties to preserve some metadata
        let originalProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        let origWidth = cgImage.width
        let origHeight = cgImage.height
        let longEdge = max(origWidth, origHeight)

        // Calculate new dimensions (no upscale)
        let scale: CGFloat
        if longEdge <= maxLongEdge {
            scale = 1.0
        } else {
            scale = CGFloat(maxLongEdge) / CGFloat(longEdge)
        }
        let newWidth = Int(CGFloat(origWidth) * scale)
        let newHeight = Int(CGFloat(origHeight) * scale)

        // Resize
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ImageProcessorError.cannotCreateContext
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resizedImage = context.makeImage() else {
            throw ImageProcessorError.cannotCreateResizedImage
        }

        // Build output properties — strip GPS and MakerNote, preserve EXIF/TIFF/IPTC
        var outputProps: [String: Any] = [:]

        // Preserve EXIF (minus sensitive fields)
        if var exif = originalProps[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
            outputProps[kCGImagePropertyExifDictionary as String] = exif
        }

        // Preserve TIFF
        if let tiff = originalProps[kCGImagePropertyTIFFDictionary as String] {
            outputProps[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        // Preserve IPTC
        if let iptc = originalProps[kCGImagePropertyIPTCDictionary as String] {
            outputProps[kCGImagePropertyIPTCDictionary as String] = iptc
        }

        // Explicitly exclude GPS — do NOT copy it

        // JPEG compression quality
        outputProps[kCGImageDestinationLossyCompressionQuality as String] = CGFloat(jpegQuality) / 100.0

        // Write
        let outputURL = URL(fileURLWithPath: outputPath) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(outputURL, "public.jpeg" as CFString, 1, nil) else {
            throw ImageProcessorError.cannotCreateDestination
        }
        CGImageDestinationAddImage(dest, resizedImage, outputProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageProcessorError.cannotWriteImage(path: outputPath)
        }
    }
}

enum ImageProcessorError: Error, LocalizedError {
    case cannotReadImage(path: String)
    case cannotCreateContext
    case cannotCreateResizedImage
    case cannotCreateDestination
    case cannotWriteImage(path: String)

    var errorDescription: String? {
        switch self {
        case .cannotReadImage(let path): return "Cannot read image: \(path)"
        case .cannotCreateContext: return "Cannot create graphics context"
        case .cannotCreateResizedImage: return "Cannot create resized image"
        case .cannotCreateDestination: return "Cannot create image destination"
        case .cannotWriteImage(let path): return "Cannot write image: \(path)"
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter ImageProcessorTests
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/quigsphoto-uploader/ImageProcessing/ImageProcessor.swift Sources/quigsphoto-uploader/ImageProcessing/CoreGraphicsImageProcessor.swift Tests/quigsphoto-uploaderTests/ImageProcessorTests.swift
git commit -m "feat: add ImageProcessor protocol and CoreGraphics implementation with resize and EXIF stripping"
```

---

## Chunk 3: Ghost CMS Integration

### Task 11: Ghost API Client (JWT Auth & HTTP)

**Files:**
- Create: `Sources/quigsphoto-uploader/Ghost/GhostClient.swift`
- Create: `Sources/quigsphoto-uploader/Ghost/GhostModels.swift`
- Create: `Tests/quigsphoto-uploaderTests/GhostClientTests.swift`

- [ ] **Step 1: Write GhostModels**

```swift
import Foundation

struct GhostPost: Codable {
    let id: String
    let title: String?
    let status: String
    let publishedAt: String?
    let updatedAt: String?
    let featureImage: String?
    let tags: [GhostTag]?

    enum CodingKeys: String, CodingKey {
        case id, title, status, tags
        case publishedAt = "published_at"
        case updatedAt = "updated_at"
        case featureImage = "feature_image"
    }
}

struct GhostTag: Codable {
    let name: String
    let slug: String?
    let visibility: String?
}

struct GhostPostsResponse: Codable {
    let posts: [GhostPost]
    let meta: GhostMeta?
}

struct GhostMeta: Codable {
    let pagination: GhostPagination
}

struct GhostPagination: Codable {
    let page: Int
    let limit: Int
    let pages: Int
    let total: Int
    let next: Int?
    let prev: Int?
}

struct GhostImageUploadResponse: Codable {
    let images: [GhostImage]
}

struct GhostImage: Codable {
    let url: String
    let ref: String?
}

struct GhostPostCreateRequest: Codable {
    let posts: [GhostPostCreate]
}

struct GhostPostCreate: Codable {
    let title: String
    let lexical: String?
    let status: String
    let publishedAt: String?
    let featureImage: String?
    let tags: [GhostTagInput]

    enum CodingKeys: String, CodingKey {
        case title, lexical, status, tags
        case publishedAt = "published_at"
        case featureImage = "feature_image"
    }
}

struct GhostTagInput: Codable {
    let name: String
}

struct GhostPostCreateResponse: Codable {
    let posts: [GhostPost]
}
```

- [ ] **Step 2: Write GhostClient JWT test**

```swift
import XCTest
@testable import quigsphoto_uploader

final class GhostClientTests: XCTestCase {
    func testJWTGeneration() throws {
        // Ghost Admin API keys are in format: id:secret (hex-encoded secret)
        let apiKey = "0000000000:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let jwt = try GhostClient.generateJWT(from: apiKey)

        // JWT has 3 parts separated by dots
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)

        // Decode header
        let headerData = Data(base64URLEncoded: String(parts[0]))!
        let header = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "HS256")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        XCTAssertEqual(header["kid"] as? String, "0000000000")
    }

    func testExtractFilenameFromGhostURL() {
        let url = "https://quigs.photo/content/images/2026/03/IMG_1234.jpg"
        XCTAssertEqual(GhostClient.extractFilename(from: url), "IMG_1234.jpg")

        let url2 = "https://example.com/images/photo.jpeg"
        XCTAssertEqual(GhostClient.extractFilename(from: url2), "photo.jpeg")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift test --filter GhostClientTests
```

Expected: compilation error.

- [ ] **Step 4: Implement GhostClient**

```swift
import Foundation
import Logging
import CommonCrypto

final class GhostClient {
    let baseURL: String
    private let apiKey: String
    private let session: URLSession
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).ghost")

    init(baseURL: String, apiKey: String, timeoutInterval: TimeInterval = 30) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutInterval
        self.session = URLSession(configuration: config)
    }

    // MARK: - JWT

    static func generateJWT(from apiKey: String) throws -> String {
        let parts = apiKey.split(separator: ":")
        guard parts.count == 2 else {
            throw GhostClientError.invalidAPIKey
        }
        let keyId = String(parts[0])
        let secretHex = String(parts[1])

        guard let secretData = Data(hexEncoded: secretHex) else {
            throw GhostClientError.invalidAPIKey
        }

        let header = #"{"alg":"HS256","typ":"JWT","kid":"\#(keyId)"}"#
        let now = Int(Date().timeIntervalSince1970)
        let payload = #"{"iat":\#(now),"exp":\#(now + 300),"aud":"/admin/"}"#

        let headerB64 = Data(header.utf8).base64URLEncodedString()
        let payloadB64 = Data(payload.utf8).base64URLEncodedString()
        let signingInput = "\(headerB64).\(payloadB64)"

        let signature = hmacSHA256(data: Data(signingInput.utf8), key: secretData)
        let signatureB64 = signature.base64URLEncodedString()

        return "\(headerB64).\(payloadB64).\(signatureB64)"
    }

    private static func hmacSHA256(data: Data, key: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBytes.baseAddress, key.count,
                       dataBytes.baseAddress, data.count,
                       &hmac)
            }
        }
        return Data(hmac)
    }

    // MARK: - API Methods

    func getPosts(status: String, filter: String?, page: Int = 1, limit: Int = 50) async throws -> GhostPostsResponse {
        var urlComponents = URLComponents(string: "\(baseURL)/ghost/api/admin/posts/")!
        var queryItems = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "order", value: "published_at desc"),
            URLQueryItem(name: "include", value: "tags"),
        ]
        if let filter {
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }
        urlComponents.queryItems = queryItems

        let data = try await authenticatedRequest(url: urlComponents.url!)
        let decoder = JSONDecoder()
        return try decoder.decode(GhostPostsResponse.self, from: data)
    }

    func uploadImage(filePath: String, filename: String) async throws -> String {
        let url = URL(string: "\(baseURL)/ghost/api/admin/images/upload/")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let jwt = try Self.generateJWT(from: apiKey)
        request.setValue("Ghost \(jwt)", forHTTPHeaderField: "Authorization")

        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        let decoded = try JSONDecoder().decode(GhostImageUploadResponse.self, from: data)
        guard let imageURL = decoded.images.first?.url else {
            throw GhostClientError.noImageURL
        }
        return imageURL
    }

    func createPost(_ post: GhostPostCreate) async throws -> GhostPost {
        let url = URL(string: "\(baseURL)/ghost/api/admin/posts/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let jwt = try Self.generateJWT(from: apiKey)
        request.setValue("Ghost \(jwt)", forHTTPHeaderField: "Authorization")

        let body = GhostPostCreateRequest(posts: [post])
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        let decoded = try JSONDecoder().decode(GhostPostCreateResponse.self, from: data)
        guard let createdPost = decoded.posts.first else {
            throw GhostClientError.noPostReturned
        }
        return createdPost
    }

    // MARK: - Helpers

    static func extractFilename(from url: String) -> String? {
        URL(string: url)?.lastPathComponent
    }

    private func authenticatedRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        let jwt = try Self.generateJWT(from: apiKey)
        request.setValue("Ghost \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GhostClientError.httpError(statusCode: httpResponse.statusCode)
        }
    }
}

enum GhostClientError: Error, LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case httpError(statusCode: Int)
    case noImageURL
    case noPostReturned

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid Ghost Admin API key format (expected id:secret)"
        case .invalidResponse: return "Invalid HTTP response"
        case .httpError(let code): return "Ghost API error: HTTP \(code)"
        case .noImageURL: return "No image URL in upload response"
        case .noPostReturned: return "No post returned from create"
        }
    }
}

// MARK: - Data extensions for JWT

extension Data {
    init?(hexEncoded hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex
        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter GhostClientTests
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/quigsphoto-uploader/Ghost/GhostClient.swift Sources/quigsphoto-uploader/Ghost/GhostModels.swift Tests/quigsphoto-uploaderTests/GhostClientTests.swift
git commit -m "feat: add Ghost API client with JWT auth, image upload, and post creation"
```

---

### Task 12: Lexical Builder

**Files:**
- Create: `Sources/quigsphoto-uploader/Ghost/LexicalBuilder.swift`
- Create: `Tests/quigsphoto-uploaderTests/LexicalBuilderTests.swift`

- [ ] **Step 1: Write LexicalBuilder tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class LexicalBuilderTests: XCTestCase {
    func testBuildWithImageAndText() throws {
        let lexical = LexicalBuilder.build(
            imageURL: "https://quigs.photo/content/images/photo.jpg",
            title: "Sunset",
            description: "Beautiful sunset over the ocean"
        )

        // Should be valid JSON
        let data = lexical.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["root"])

        // Should contain the image URL
        XCTAssertTrue(lexical.contains("photo.jpg"))
        // Should contain the text
        XCTAssertTrue(lexical.contains("Sunset"))
        XCTAssertTrue(lexical.contains("Beautiful sunset"))
    }

    func testBuildWithImageOnly() throws {
        let lexical = LexicalBuilder.build(
            imageURL: "https://quigs.photo/content/images/photo.jpg",
            title: nil,
            description: nil
        )

        let data = lexical.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["root"])
        XCTAssertTrue(lexical.contains("photo.jpg"))
    }

    func testBuildWithTitleNoDescription() throws {
        let lexical = LexicalBuilder.build(
            imageURL: "https://example.com/img.jpg",
            title: "My Photo",
            description: nil
        )

        XCTAssertTrue(lexical.contains("My Photo"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter LexicalBuilderTests
```

Expected: compilation error.

- [ ] **Step 3: Implement LexicalBuilder**

```swift
import Foundation

enum LexicalBuilder {
    /// Build a Lexical JSON string for a Ghost post with an image and optional text.
    static func build(imageURL: String, title: String?, description: String?) -> String {
        var children: [[String: Any]] = []

        // Image card
        let imageCard: [String: Any] = [
            "type": "image",
            "version": 1,
            "src": imageURL,
            "width": 0,
            "height": 0,
            "title": "",
            "alt": "",
            "caption": "",
            "cardWidth": "wide",
        ]
        children.append(imageCard)

        // Title paragraph (for 365 Project body, EXIF title goes here)
        if let title, !title.isEmpty {
            let paragraph: [String: Any] = [
                "type": "paragraph",
                "version": 1,
                "children": [
                    [
                        "type": "text",
                        "version": 1,
                        "text": title,
                        "format": 0,
                        "detail": 0,
                        "mode": "normal",
                        "style": "",
                    ] as [String: Any]
                ],
                "direction": "ltr",
                "format": "",
                "indent": 0,
                "textFormat": 0,
                "textStyle": "",
            ]
            children.append(paragraph)
        }

        // Description paragraph
        if let description, !description.isEmpty {
            let paragraph: [String: Any] = [
                "type": "paragraph",
                "version": 1,
                "children": [
                    [
                        "type": "text",
                        "version": 1,
                        "text": description,
                        "format": 0,
                        "detail": 0,
                        "mode": "normal",
                        "style": "",
                    ] as [String: Any]
                ],
                "direction": "ltr",
                "format": "",
                "indent": 0,
                "textFormat": 0,
                "textStyle": "",
            ]
            children.append(paragraph)
        }

        let root: [String: Any] = [
            "root": [
                "type": "root",
                "version": 1,
                "children": children,
                "direction": "ltr",
                "format": "",
                "indent": 0,
            ] as [String: Any]
        ]

        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter LexicalBuilderTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Ghost/LexicalBuilder.swift Tests/quigsphoto-uploaderTests/LexicalBuilderTests.swift
git commit -m "feat: add LexicalBuilder for Ghost post body formatting"
```

---

### Task 13: Ghost Deduplicator

**Files:**
- Create: `Sources/quigsphoto-uploader/Ghost/GhostDeduplicator.swift`
- Create: `Tests/quigsphoto-uploaderTests/GhostDeduplicatorTests.swift`

- [ ] **Step 1: Write GhostDeduplicator tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class GhostDeduplicatorTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-uploader-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testCacheHitReturnsDuplicate() throws {
        let logPath = tmpDir.appendingPathComponent("upload-log.jsonl").path
        let log = UploadLog(path: logPath)
        let entry = UploadLogEntry(
            filename: "IMG_001.jpg",
            ghostUrl: "https://quigs.photo/p/test",
            postId: "abc",
            timestamp: Date()
        )
        try log.append(entry)

        let dedup = GhostDeduplicator(uploadLog: log, client: nil)
        let result = try dedup.checkCacheOnly(filename: "IMG_001.jpg")
        XCTAssertTrue(result)
    }

    func testCacheMissReturnsNotDuplicate() throws {
        let logPath = tmpDir.appendingPathComponent("upload-log.jsonl").path
        let log = UploadLog(path: logPath)

        let dedup = GhostDeduplicator(uploadLog: log, client: nil)
        let result = try dedup.checkCacheOnly(filename: "IMG_999.jpg")
        XCTAssertFalse(result)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter GhostDeduplicatorTests
```

Expected: compilation error.

- [ ] **Step 3: Implement GhostDeduplicator**

```swift
import Foundation
import Logging

struct GhostDeduplicator {
    private let uploadLog: UploadLog
    private let client: GhostClient?
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).dedup")
    private let maxAge: TimeInterval = 365 * 24 * 60 * 60 // 1 year

    init(uploadLog: UploadLog, client: GhostClient?) {
        self.uploadLog = uploadLog
        self.client = client
    }

    /// Check local cache only (for unit tests without Ghost)
    func checkCacheOnly(filename: String) throws -> Bool {
        try uploadLog.contains(filename: filename)
    }

    /// Full two-tier dedup: cache first, then Ghost API.
    /// Throws `GhostDeduplicatorError.apiFailed` on Ghost API failure (fatal per spec).
    func isDuplicate(filename: String) async throws -> Bool {
        // Tier 1: local cache
        if try uploadLog.contains(filename: filename) {
            logger.info("Dedup cache hit: \(filename)")
            return true
        }

        // Tier 2: Ghost API
        guard let client else {
            return false
        }

        let dateFormatter = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-maxAge)

        do {
            for status in ["published", "scheduled", "draft"] {
                var page = 1
                pageLoop: while true {
                    let response = try await client.getPosts(status: status, filter: nil, page: page)
                    for post in response.posts {
                        // Check if post is too old
                        if let dateStr = post.publishedAt ?? post.updatedAt,
                           let date = dateFormatter.date(from: dateStr),
                           date < cutoff {
                            break pageLoop
                        }
                        // Check feature image filename
                        if let featureImage = post.featureImage,
                           let postFilename = GhostClient.extractFilename(from: featureImage),
                           postFilename == filename {
                            logger.info("Dedup Ghost API hit: \(filename) (post \(post.id))")
                            // Self-heal: add to cache
                            let entry = UploadLogEntry(
                                filename: filename,
                                ghostUrl: featureImage,
                                postId: post.id,
                                timestamp: Date()
                            )
                            try? uploadLog.append(entry)
                            return true
                        }
                    }
                    // Check if there are more pages
                    guard let meta = response.meta, meta.pagination.next != nil else {
                        break
                    }
                    page += 1
                }
            }
        } catch {
            throw GhostDeduplicatorError.apiFailed(underlying: error)
        }

        return false
    }
}

enum GhostDeduplicatorError: Error, LocalizedError {
    case apiFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .apiFailed(let err):
            return "Ghost API dedup query failed (fatal): \(err.localizedDescription)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter GhostDeduplicatorTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Ghost/GhostDeduplicator.swift Tests/quigsphoto-uploaderTests/GhostDeduplicatorTests.swift
git commit -m "feat: add two-tier deduplicator with local cache and Ghost API fallback"
```

---

### Task 14: Ghost Scheduler

**Files:**
- Create: `Sources/quigsphoto-uploader/Ghost/GhostScheduler.swift`
- Create: `Tests/quigsphoto-uploaderTests/GhostSchedulerTests.swift`

- [ ] **Step 1: Write GhostScheduler tests**

```swift
import XCTest
@testable import quigsphoto_uploader

final class GhostSchedulerTests: XCTestCase {
    func testRandomTimeInWindow() {
        let window = AppConfig.GhostConfig.SchedulingWindow(
            start: "08:00", end: "10:00", timezone: "America/New_York"
        )
        // Run multiple times to verify it's in range
        for _ in 0..<20 {
            let (hour, minute) = GhostScheduler.randomTimeInWindow(window)
            let totalMinutes = hour * 60 + minute
            XCTAssertGreaterThanOrEqual(totalMinutes, 8 * 60)
            XCTAssertLessThan(totalMinutes, 10 * 60)
        }
    }

    func testFormatScheduleDate() {
        let components = DateComponents(
            timeZone: TimeZone(identifier: "America/New_York"),
            year: 2026, month: 3, day: 20,
            hour: 9, minute: 15
        )
        let date = Calendar.current.date(from: components)!
        let formatted = GhostScheduler.formatForGhost(date: date)
        // Ghost expects ISO 8601
        XCTAssertTrue(formatted.contains("2026-03-20"))
    }

    func testDay365Calculation() {
        let refDate = "2025-12-25"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Day 1 = Dec 26, 2025
        let day1 = formatter.date(from: "2025:12:26 10:00:00")!
        XCTAssertEqual(GhostScheduler.calculate365DayNumber(photoDate: day1, referenceDate: refDate), 1)

        // Day 10 = Jan 3, 2026
        let day10 = formatter.date(from: "2026:01:03 10:00:00")!
        XCTAssertEqual(GhostScheduler.calculate365DayNumber(photoDate: day10, referenceDate: refDate), 10)

        // Reference date itself = day 0... but spec says +1, so this is day 1 if same day
        let refDay = formatter.date(from: "2025:12:25 10:00:00")!
        // Days since ref = 0, +1 = 1? Spec says "(DateTimeOriginal - referenceDate) + 1"
        // If photo taken ON reference date, that's 0 days difference + 1 = 1
        XCTAssertEqual(GhostScheduler.calculate365DayNumber(photoDate: refDay, referenceDate: refDate), 1)
    }

    func testDay365BeforeReferenceDate() {
        let refDate = "2025-12-25"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let beforeRef = formatter.date(from: "2025:12:20 10:00:00")!
        // 5 days before, absolute + 1 = 6
        let dayNum = GhostScheduler.calculate365DayNumber(photoDate: beforeRef, referenceDate: refDate)
        XCTAssertEqual(dayNum, 6)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter GhostSchedulerTests
```

Expected: compilation error.

- [ ] **Step 3: Implement GhostScheduler**

```swift
import Foundation
import Logging

struct GhostScheduler {
    private let client: GhostClient
    private let config: AppConfig.GhostConfig
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).scheduler")

    init(client: GhostClient, config: AppConfig.GhostConfig) {
        self.client = client
        self.config = config
    }

    /// Determine the next schedule date for a post in the given category.
    func nextScheduleDate(is365Project: Bool) async throws -> Date {
        let filter: String
        if is365Project {
            filter = "tag:365+Project"
        } else {
            filter = "tag:#image-post+tag:-365+Project"
        }

        // Check scheduled posts first
        let scheduled = try await client.getPosts(status: "scheduled", filter: filter, limit: 50)
        if !scheduled.posts.isEmpty {
            // Find the most distant scheduled post
            let formatter = ISO8601DateFormatter()
            let dates = scheduled.posts.compactMap { post -> Date? in
                guard let dateStr = post.publishedAt else { return nil }
                return formatter.date(from: dateStr)
            }
            if let maxDate = dates.max() {
                return Calendar.current.date(byAdding: .day, value: 1, to: maxDate)!
            }
        }

        // No scheduled posts — check most recent published
        let published = try await client.getPosts(status: "published", filter: filter, limit: 1)
        if let latestPost = published.posts.first,
           let dateStr = latestPost.publishedAt,
           let pubDate = ISO8601DateFormatter().date(from: dateStr) {
            if Calendar.current.isDateInToday(pubDate) {
                return Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            }
        }

        return Date()
    }

    /// Build a full schedule datetime with random time in window.
    func buildScheduleDateTime(baseDate: Date) -> Date {
        let (hour, minute) = Self.randomTimeInWindow(config.schedulingWindow)
        guard let tz = TimeZone(identifier: config.schedulingWindow.timezone) else {
            return baseDate
        }
        var calendar = Calendar.current
        calendar.timeZone = tz
        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? baseDate
    }

    // MARK: - Static helpers

    static func randomTimeInWindow(_ window: AppConfig.GhostConfig.SchedulingWindow) -> (hour: Int, minute: Int) {
        let startParts = window.start.split(separator: ":").map { Int($0)! }
        let endParts = window.end.split(separator: ":").map { Int($0)! }
        let startMinutes = startParts[0] * 60 + startParts[1]
        let endMinutes = endParts[0] * 60 + endParts[1]
        let randomMinutes = Int.random(in: startMinutes..<endMinutes)
        return (hour: randomMinutes / 60, minute: randomMinutes % 60)
    }

    static func formatForGhost(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func calculate365DayNumber(photoDate: Date, referenceDate: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let refDate = formatter.date(from: referenceDate) else { return 1 }

        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: refDate), to: calendar.startOfDay(for: photoDate)).day ?? 0
        return abs(days) + 1
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter GhostSchedulerTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Ghost/GhostScheduler.swift Tests/quigsphoto-uploaderTests/GhostSchedulerTests.swift
git commit -m "feat: add GhostScheduler with queue detection, scheduling logic, and 365 day calculation"
```

---

## Chunk 4: Email, Setup, and Orchestration

### Task 15: Email Sender

**Files:**
- Create: `Sources/quigsphoto-uploader/Email/EmailSender.swift`

- [ ] **Step 1: Implement EmailSender**

```swift
import Foundation
import Logging
import SwiftSMTP

struct EmailSender {
    private let config: AppConfig.SMTPConfig
    private let secretStore: SecretStore
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).email")

    init(config: AppConfig.SMTPConfig, secretStore: SecretStore) {
        self.config = config
        self.secretStore = secretStore
    }

    func send(
        to: String,
        subject: String,
        body: String,
        attachmentPath: String,
        attachmentFilename: String
    ) throws {
        let password = try secretStore.get(key: "\(AppConstants.keychainServicePrefix)-smtp")

        let smtp = SMTP(
            hostname: config.host,
            email: config.username,
            password: password,
            port: Int32(config.port),
            tlsMode: .requireSTARTTLS
        )

        let from = Mail.User(email: config.from)
        let toUser = Mail.User(email: to)

        let attachment = Attachment(
            filePath: attachmentPath,
            mime: "image/jpeg",
            name: attachmentFilename
        )

        let mail = Mail(
            from: from,
            to: [toUser],
            subject: subject,
            text: body,
            attachments: [attachment]
        )

        var sendError: Error?
        smtp.send(mail) { error in
            sendError = error
        }

        if let error = sendError {
            throw EmailSenderError.sendFailed(error.localizedDescription)
        }

        logger.info("Email sent to \(to): \(subject)")
    }
}

enum EmailSenderError: Error, LocalizedError {
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .sendFailed(let msg): return "Email send failed: \(msg)"
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
swift build
```

Expected: clean build. (SMTP tests require a real server — manual testing only.)

- [ ] **Step 3: Commit**

```bash
git add Sources/quigsphoto-uploader/Email/EmailSender.swift
git commit -m "feat: add EmailSender with SMTP support via SwiftSMTP"
```

---

### Task 16: Setup Command

**Files:**
- Modify: `Sources/quigsphoto-uploader/CLI/SetupCommand.swift`

- [ ] **Step 1: Implement interactive setup**

```swift
import ArgumentParser
import Foundation

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup — configure Ghost, SMTP, and processing settings"
    )

    func run() throws {
        print("Welcome to \(AppConstants.binaryName) setup!")
        print("This will walk you through configuring the tool.\n")

        // Ghost
        let ghostURL = prompt("Ghost CMS URL (e.g., https://quigs.photo):")
        let windowStart = prompt("Scheduling window start (HH:MM, default 08:00):", default: "08:00")
        let windowEnd = prompt("Scheduling window end (HH:MM, default 10:00):", default: "10:00")
        let timezone = prompt("Timezone (e.g., America/New_York):", default: "America/New_York")

        // Processing
        let maxLongEdgeStr = prompt("Max long edge pixels (default 2000):", default: "2000")
        let maxLongEdge = Int(maxLongEdgeStr) ?? 2000
        let jpegQualityStr = prompt("JPEG quality 1-100 (default 80):", default: "80")
        let jpegQuality = Int(jpegQualityStr) ?? 80

        // 365 Project
        let keyword365 = prompt("365 Project keyword (default \"365 Project\"):", default: "365 Project")
        let refDate = prompt("365 Project reference date (YYYY-MM-DD, default 2025-12-25):", default: "2025-12-25")
        let emailTo = prompt("365 Project email address:")

        // SMTP
        let smtpHost = prompt("SMTP host:")
        let smtpPortStr = prompt("SMTP port (default 587):", default: "587")
        let smtpPort = Int(smtpPortStr) ?? 587
        let smtpUsername = prompt("SMTP username:")
        let smtpFrom = prompt("SMTP from address (default: same as username):", default: smtpUsername)

        // Tag blocklist
        let blocklistStr = prompt("Tag blocklist (comma-separated, or empty):", default: "")
        let blocklist = blocklistStr.isEmpty ? [] : blocklistStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

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

        try config.save(to: AppConfig.configPath.path)
        print("\nConfig saved to \(AppConfig.configPath.path)")

        // Secrets
        let secretStore = KeychainSecretStore()

        let ghostAPIKey = promptSecret("Ghost Admin API key (id:secret):")
        try secretStore.set(key: "\(AppConstants.keychainServicePrefix)-ghost", value: ghostAPIKey)
        print("Ghost API key saved to Keychain.")

        let smtpPassword = promptSecret("SMTP password:")
        try secretStore.set(key: "\(AppConstants.keychainServicePrefix)-smtp", value: smtpPassword)
        print("SMTP password saved to Keychain.")

        print("\nSetup complete! Run `\(AppConstants.binaryName) process <folder>` to start processing.")
    }

    private func prompt(_ message: String, default defaultValue: String? = nil) -> String {
        if let defaultValue {
            print("\(message) [\(defaultValue)] ", terminator: "")
        } else {
            print("\(message) ", terminator: "")
        }
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.isEmpty else {
            return defaultValue ?? ""
        }
        return input
    }

    private func promptSecret(_ message: String) -> String {
        print("\(message) ", terminator: "")
        // In a real implementation, you'd disable echo here
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return input
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
swift build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/quigsphoto-uploader/CLI/SetupCommand.swift
git commit -m "feat: add interactive setup command with config creation and Keychain storage"
```

---

### Task 17: Process Command (Full Orchestration)

**Files:**
- Modify: `Sources/quigsphoto-uploader/CLI/ProcessCommand.swift`

This is the main orchestration — ties everything together.

- [ ] **Step 1: Implement ProcessCommand**

```swift
import ArgumentParser
import Foundation
import Logging

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process all images in a folder and publish to Ghost CMS"
    )

    @Argument(help: "Path to folder containing exported images")
    var folderPath: String

    @Flag(help: "Preview actions without uploading or emailing")
    var dryRun = false

    @Flag(help: "Include successful images in result output")
    var verboseResults = false

    @Flag(help: "Write a single JSON results file instead of individual text files")
    var jsonResults = false

    @Option(help: "Directory to write result files to (default: input folder)")
    var resultsDir: String?

    func run() async throws {
        let logger = Logger(label: "\(AppConstants.loggerPrefix).process")

        // Load config
        guard FileManager.default.fileExists(atPath: AppConfig.configPath.path) else {
            logger.error("Config not found. Run `\(AppConstants.binaryName) setup` first.")
            throw ExitCode(1)
        }
        let config = try AppConfig.load(from: AppConfig.configPath.path)

        // Acquire lock
        let lockPath = NSTemporaryDirectory() + "\(AppConstants.tempDirectoryName)/\(AppConstants.binaryName).lock"
        let lock: ProcessLock
        do {
            lock = try ProcessLock(path: lockPath)
        } catch ProcessLockError.alreadyRunning {
            logger.error("Another instance of \(AppConstants.binaryName) is already running.")
            throw ExitCode(1)
        }
        defer { lock.release() }

        // Create temp directory for resized images (separate from lock dir)
        let tempDir = NSTemporaryDirectory() + "\(AppConstants.tempDirectoryName)/images/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        // Initialize components
        let secretStore = KeychainSecretStore()
        let ghostAPIKey = try secretStore.get(key: "\(AppConstants.keychainServicePrefix)-ghost")
        let ghostClient = GhostClient(baseURL: config.ghost.url, apiKey: ghostAPIKey)
        let metadataReader = CGImageMetadataReader()
        let imageProcessor = CoreGraphicsImageProcessor()
        let scanner = ImageScanner(metadataReader: metadataReader)
        let uploadLog = UploadLog(path: AppConfig.configDirectory.appendingPathComponent("upload-log.jsonl").path)
        let emailLog = EmailLog(path: AppConfig.configDirectory.appendingPathComponent("email-log.jsonl").path)
        let deduplicator = GhostDeduplicator(uploadLog: uploadLog, client: ghostClient)
        let scheduler = GhostScheduler(client: ghostClient, config: config.ghost)

        // Seed email log from Ghost if it doesn't exist
        if !emailLog.fileExists {
            logger.info("Email log not found — seeding from Ghost...")
            await seedEmailLog(emailLog: emailLog, client: ghostClient, config: config)
        }

        // Scan and sort images
        logger.info("Scanning folder: \(folderPath)")
        let images = try scanner.scan(folder: folderPath)
        logger.info("Found \(images.count) images")

        var results = ProcessingResults()
        var emailCandidates: [(ScannedImage, String)] = [] // (image, resizedPath)

        // Process each image
        for image in images {
            do {
                let processedKeywords = ImageMetadata.processKeywords(
                    image.metadata.keywords,
                    blocklist: config.tagBlocklist
                )
                let is365 = image.metadata.is365Project(keyword: config.project365.keyword)

                // Dedup check (Ghost API failure is fatal — let GhostDeduplicatorError propagate)
                let isDup: Bool
                do {
                    isDup = try await deduplicator.isDuplicate(filename: image.filename)
                } catch is GhostDeduplicatorError {
                    logger.error("Fatal: Ghost API dedup query failed — aborting to avoid duplicates")
                    throw ExitCode(1)
                }
                if isDup {
                    logger.info("[\(image.filename)] Duplicate — skipping Ghost upload")
                    results.duplicates.append(image.filename)
                    // Still check email for 365 Project
                    if is365 {
                        let resizedPath = tempDir + image.filename
                        if !FileManager.default.fileExists(atPath: resizedPath) {
                            try imageProcessor.process(
                                inputPath: image.path,
                                outputPath: resizedPath,
                                maxLongEdge: config.processing.maxLongEdge,
                                jpegQuality: config.processing.jpegQuality
                            )
                        }
                        emailCandidates.append((image, resizedPath))
                    }
                    continue
                }

                // Resize image
                let resizedPath = tempDir + image.filename
                logger.info("[\(image.filename)] Resizing...")
                if !dryRun {
                    try imageProcessor.process(
                        inputPath: image.path,
                        outputPath: resizedPath,
                        maxLongEdge: config.processing.maxLongEdge,
                        jpegQuality: config.processing.jpegQuality
                    )
                }

                // Check if we have enough metadata for a scheduled post
                let hasTitle: Bool
                let postTitle: String
                if is365 {
                    let dayNumber = GhostScheduler.calculate365DayNumber(
                        photoDate: image.metadata.dateTimeOriginal ?? Date(),
                        referenceDate: config.project365.referenceDate
                    )
                    postTitle = "365 Project #\(dayNumber)"
                    hasTitle = true // 365 Project always has a title
                } else {
                    if let title = image.metadata.title {
                        postTitle = title
                        hasTitle = true
                    } else {
                        postTitle = image.filename
                        hasTitle = false
                    }
                }

                // Build tags
                var tags: [GhostTagInput] = []
                if is365 {
                    tags.append(GhostTagInput(name: config.project365.keyword))
                }
                for keyword in processedKeywords where keyword != config.project365.keyword {
                    tags.append(GhostTagInput(name: keyword))
                }
                tags.append(GhostTagInput(name: "#image-post"))
                tags.append(GhostTagInput(name: "#photo-stream"))

                // Build body
                let bodyTitle = is365 ? image.metadata.title : nil
                let bodyDescription = image.metadata.description
                let status = hasTitle ? "scheduled" : "draft"

                if dryRun {
                    logger.info("[\(image.filename)] Would \(status): \"\(postTitle)\"")
                    if status == "scheduled" {
                        results.scheduled.append(image.filename)
                    } else {
                        results.drafts.append(image.filename)
                    }
                    results.successes.append(image.filename)
                    continue
                }

                // Upload image to Ghost
                logger.info("[\(image.filename)] Uploading to Ghost...")
                let imageURL = try await ghostClient.uploadImage(filePath: resizedPath, filename: image.filename)

                // Build Lexical content
                let lexical = LexicalBuilder.build(
                    imageURL: imageURL,
                    title: bodyTitle,
                    description: bodyDescription
                )

                // Determine schedule date
                var publishedAt: String?
                if hasTitle {
                    let scheduleDate = try await scheduler.nextScheduleDate(is365Project: is365)
                    let dateTime = scheduler.buildScheduleDateTime(baseDate: scheduleDate)
                    publishedAt = GhostScheduler.formatForGhost(date: dateTime)
                }

                // Create post
                let post = GhostPostCreate(
                    title: postTitle,
                    lexical: lexical,
                    status: status,
                    publishedAt: publishedAt,
                    featureImage: imageURL,
                    tags: tags
                )
                let created = try await ghostClient.createPost(post)
                logger.info("[\(image.filename)] \(status == "scheduled" ? "Scheduled" : "Draft"): \(postTitle) (post \(created.id))")

                if status == "scheduled" {
                    results.scheduled.append(image.filename)
                } else {
                    results.drafts.append(image.filename)
                }

                // Log successful upload
                let logEntry = UploadLogEntry(
                    filename: image.filename,
                    ghostUrl: "\(config.ghost.url)/p/\(created.id)",
                    postId: created.id,
                    timestamp: Date()
                )
                try uploadLog.append(logEntry)

                results.successes.append(image.filename)

                // Add to email candidates if 365 Project and scheduled (not draft)
                if is365 && hasTitle {
                    emailCandidates.append((image, resizedPath))
                }

            } catch {
                logger.error("[\(image.filename)] Error: \(error.localizedDescription)")
                results.failures.append(image.filename)
            }
        }

        // Email phase
        if !emailCandidates.isEmpty && !dryRun {
            logger.info("Sending 365 Project emails...")
            let emailSender = EmailSender(config: config.smtp, secretStore: secretStore)

            for (image, resizedPath) in emailCandidates {
                do {
                    // Email dedup
                    if try emailLog.contains(filename: image.filename) {
                        logger.info("[\(image.filename)] Email already sent — skipping")
                        continue
                    }

                    let subject = image.metadata.title ?? image.filename
                    let body = image.metadata.description ?? ""

                    try emailSender.send(
                        to: config.project365.emailTo,
                        subject: subject,
                        body: body,
                        attachmentPath: resizedPath,
                        attachmentFilename: image.filename
                    )

                    // Log successful email
                    let entry = EmailLogEntry(
                        filename: image.filename,
                        emailTo: config.project365.emailTo,
                        subject: subject,
                        timestamp: Date()
                    )
                    try emailLog.append(entry)
                    logger.info("[\(image.filename)] Email sent")
                } catch {
                    logger.error("[\(image.filename)] Email error: \(error.localizedDescription)")
                    // Email errors are non-fatal
                }
            }
        }

        // Write results
        let outputDir = resultsDir ?? folderPath
        if jsonResults {
            try ResultsWriter.writeJSON(results: results, to: outputDir, verbose: verboseResults)
        } else {
            try ResultsWriter.writeText(results: results, to: outputDir, verbose: verboseResults)
        }

        // Summary
        let summary = "Processed \(images.count) images: \(results.scheduled.count) scheduled, \(results.drafts.count) drafts, \(results.duplicates.count) duplicates, \(results.failures.count) errors"
        logger.info("\(summary)")

        // Exit code
        if !results.failures.isEmpty {
            throw ExitCode(2)
        }
    }

    private func seedEmailLog(emailLog: EmailLog, client: GhostClient, config: AppConfig) async {
        let logger = Logger(label: "\(AppConstants.loggerPrefix).email-seed")
        do {
            var page = 1
            let cutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60)
            let filterKeyword = config.project365.keyword.replacingOccurrences(of: " ", with: "+")
            seedLoop: while true {
                let response = try await client.getPosts(
                    status: "published",
                    filter: "tag:\(filterKeyword)",
                    page: page
                )
                for post in response.posts {
                    if let dateStr = post.publishedAt,
                       let date = ISO8601DateFormatter().date(from: dateStr),
                       date < cutoff { break seedLoop }
                    if let featureImage = post.featureImage,
                       let filename = GhostClient.extractFilename(from: featureImage) {
                        let entry = EmailLogEntry(
                            filename: filename,
                            emailTo: config.project365.emailTo,
                            subject: post.title ?? "",
                            timestamp: Date()
                        )
                        try emailLog.append(entry)
                    }
                }
                guard let meta = response.meta, meta.pagination.next != nil else { break }
                page += 1
            }
            logger.info("Email log seeded from Ghost")
        } catch {
            logger.warning("Failed to seed email log: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Update main.swift for async support**

```swift
import ArgumentParser

@main
struct QuigsphotoUploader: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quigsphoto-uploader",
        abstract: "Process and publish photos to Ghost CMS",
        subcommands: [ProcessCommand.self, SetupCommand.self]
    )
}
```

- [ ] **Step 3: Build to verify compilation**

```bash
swift build
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/quigsphoto-uploader/CLI/ProcessCommand.swift Sources/quigsphoto-uploader/main.swift
git commit -m "feat: add ProcessCommand with full orchestration — scan, dedup, upload, schedule, email, results"
```

---

### Task 18: Run Full Test Suite

- [ ] **Step 1: Run all tests**

```bash
swift test
```

Expected: all unit tests pass.

- [ ] **Step 2: Fix any compilation or test failures**

Address any issues found.

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve test and compilation issues"
```

---

### Task 19: Manual Integration Test

- [ ] **Step 1: Run setup**

```bash
swift run quigsphoto-uploader setup
```

Walk through the interactive setup with real Ghost credentials.

- [ ] **Step 2: Test with dry run**

Create a test folder with a few JPEG images (some with 365 Project keyword, some without).

```bash
swift run quigsphoto-uploader process /path/to/test-folder --dry-run --verbose-results
```

Verify: correct sorting, dedup detection, scheduling logic, result files.

- [ ] **Step 3: Test with real upload**

```bash
swift run quigsphoto-uploader process /path/to/test-folder --verbose-results
```

Verify: images uploaded to Ghost, posts created/scheduled, emails sent for 365 Project images, dedup logs populated.

- [ ] **Step 4: Test re-run (dedup)**

```bash
swift run quigsphoto-uploader process /path/to/test-folder --verbose-results
```

Verify: all images detected as duplicates from local cache, no new Ghost posts.

- [ ] **Step 5: Commit any fixes from integration testing**

```bash
git add -A
git commit -m "fix: integration test fixes"
```
