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
            ghost: .init(url: "https://example.com", schedulingWindow: .init(start: "09:00", end: "11:00", timezone: "UTC")),
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

    func testMetadataAllowlistDefaultsWhenMissing() throws {
        let json = """
        {
            "ghost": {
                "url": "https://quigs.photo",
                "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
            },
            "processing": {
                "maxLongEdge": 2000,
                "jpegQuality": 80
            },
            "project365": {
                "keyword": "365 Project",
                "referenceDate": "2025-12-25",
                "emailTo": "test@test.com"
            },
            "smtp": { "host": "smtp.test.com", "port": 587, "username": "u", "from": "u@t.com" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.processing.metadataAllowlist, AppConfig.ProcessingConfig.defaultMetadataAllowlist)
        XCTAssertTrue(config.processing.metadataAllowlist.contains("TIFF.Make"))
        XCTAssertTrue(config.processing.metadataAllowlist.contains("EXIF.DateTimeOriginal"))
        XCTAssertTrue(config.processing.metadataAllowlist.contains("IPTC.DigitalSourceType"))
    }

    func testMetadataAllowlistCustomValues() throws {
        let json = """
        {
            "ghost": {
                "url": "https://quigs.photo",
                "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
            },
            "processing": {
                "maxLongEdge": 2000,
                "jpegQuality": 80,
                "metadataAllowlist": ["TIFF.Make"]
            },
            "project365": {
                "keyword": "365 Project",
                "referenceDate": "2025-12-25",
                "emailTo": "test@test.com"
            },
            "smtp": { "host": "smtp.test.com", "port": 587, "username": "u", "from": "u@t.com" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.processing.metadataAllowlist, ["TIFF.Make"])
    }

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
        XCTAssertEqual(config.signing?.xmpNamespace, "http://quigs.photo/xmp/1.0/")
        XCTAssertEqual(config.signing?.xmpPrefix, "quigsphoto")
    }
}
