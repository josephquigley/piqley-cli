import Foundation

struct AppConfig: Codable, Sendable {
    var signing: SigningConfig?

    struct SigningConfig: Codable, Sendable {
        var keyFingerprint: String = ""
        var xmpNamespace: String?
        var xmpPrefix: String = "piqley"
        static let defaultXmpPrefix = "piqley"
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/config.json")
    }

    static func load(from url: URL = AppConfig.configURL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func save(to url: URL = AppConfig.configURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
