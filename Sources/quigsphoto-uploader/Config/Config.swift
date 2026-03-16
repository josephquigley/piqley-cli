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
