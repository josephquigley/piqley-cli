import Foundation

struct AppConfig: Codable, Sendable {
    /// Hook name -> ordered plugin identifier list.
    var pipeline: [String: [String]] = [:]

    // MARK: - Persistence

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.config)
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
