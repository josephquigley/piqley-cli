import Foundation

struct AppConfig: Codable, Equatable {
    var ghost: GhostConfig
    var processing: ProcessingConfig
    var project365: Project365Config
    var smtp: SMTPConfig
    var tagBlocklist: [String]
    var requiredTags: [String]
    var cameraModelTags: [String: [String]]
    var signing: SigningConfig?

    struct GhostConfig: Codable, Equatable {
        var url: String
        var schedulingWindow: SchedulingWindow
        var non365ProjectFilterTags: [String]

        struct SchedulingWindow: Codable, Equatable {
            var start: String
            var end: String
            var timezone: String
        }

        init(url: String, schedulingWindow: SchedulingWindow, non365ProjectFilterTags: [String] = []) {
            self.url = url
            self.schedulingWindow = schedulingWindow
            self.non365ProjectFilterTags = non365ProjectFilterTags
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(String.self, forKey: .url)
            schedulingWindow = try container.decode(SchedulingWindow.self, forKey: .schedulingWindow)
            non365ProjectFilterTags = try container.decodeIfPresent([String].self, forKey: .non365ProjectFilterTags) ?? []
        }
    }

    struct ProcessingConfig: Codable, Equatable {
        var maxLongEdge: Int
        var jpegQuality: Int
        var metadataAllowlist: [String]

        static let defaultMetadataAllowlist: [String] = [
            "TIFF.Make",
            "TIFF.Model",
            "TIFF.Artist",
            "TIFF.Copyright",
            "EXIF.LensMake",
            "EXIF.LensModel",
            "EXIF.FNumber",
            "EXIF.ExposureTime",
            "EXIF.ISOSpeedRatings",
            "EXIF.FocalLength",
            "EXIF.DateTimeOriginal",
            "EXIF.SubSecTimeOriginal",
            "IPTC.DigitalSourceType",
            "IPTC.CopyrightNotice",
            "IPTC.Byline",
            "IPTC.DateCreated",
            "IPTC.TimeCreated",
        ]

        init(maxLongEdge: Int, jpegQuality: Int, metadataAllowlist: [String] = ProcessingConfig.defaultMetadataAllowlist) {
            self.maxLongEdge = maxLongEdge
            self.jpegQuality = jpegQuality
            self.metadataAllowlist = metadataAllowlist
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            maxLongEdge = try container.decode(Int.self, forKey: .maxLongEdge)
            jpegQuality = try container.decode(Int.self, forKey: .jpegQuality)
            metadataAllowlist = try container.decodeIfPresent([String].self, forKey: .metadataAllowlist) ?? ProcessingConfig.defaultMetadataAllowlist
        }
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

    /// Resolved signing config with XMP namespace derived from Ghost URL if not explicitly set
    var resolvedSigningConfig: SigningConfig? {
        guard var config = signing else { return nil }
        if config.xmpNamespace == nil {
            config.xmpNamespace = SigningConfig.deriveXmpNamespace(from: ghost.url)
        }
        return config
    }

    init(
        ghost: GhostConfig,
        processing: ProcessingConfig,
        project365: Project365Config,
        smtp: SMTPConfig,
        tagBlocklist: [String] = [],
        requiredTags: [String] = [],
        cameraModelTags: [String: [String]] = [:],
        signing: SigningConfig? = nil
    ) {
        self.ghost = ghost
        self.processing = processing
        self.project365 = project365
        self.smtp = smtp
        self.tagBlocklist = tagBlocklist
        self.requiredTags = requiredTags
        self.cameraModelTags = cameraModelTags
        self.signing = signing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ghost = try container.decode(GhostConfig.self, forKey: .ghost)
        processing = try container.decode(ProcessingConfig.self, forKey: .processing)
        project365 = try container.decode(Project365Config.self, forKey: .project365)
        smtp = try container.decode(SMTPConfig.self, forKey: .smtp)
        tagBlocklist = try container.decodeIfPresent([String].self, forKey: .tagBlocklist) ?? []
        requiredTags = try container.decodeIfPresent([String].self, forKey: .requiredTags) ?? []
        cameraModelTags = try container.decodeIfPresent([String: [String]].self, forKey: .cameraModelTags) ?? [:]
        signing = try container.decodeIfPresent(SigningConfig.self, forKey: .signing)
    }

    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/\(AppConstants.name)")

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
