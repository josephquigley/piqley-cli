import Foundation

struct AppConfig: Codable, Sendable {
    var autoDiscoverPlugins: Bool = true
    var disabledPlugins: [String] = []
    /// Hook name → ordered plugin name list. Plugin names may include ":required" suffix (reserved for future use).
    var pipeline: [String: [String]] = [:]

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case autoDiscoverPlugins, disabledPlugins, pipeline
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoDiscoverPlugins = try container.decodeIfPresent(Bool.self, forKey: .autoDiscoverPlugins) ?? true
        disabledPlugins = try container.decodeIfPresent([String].self, forKey: .disabledPlugins) ?? []
        pipeline = try container.decodeIfPresent([String: [String]].self, forKey: .pipeline) ?? [:]
    }

    // MARK: - Persistence

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
