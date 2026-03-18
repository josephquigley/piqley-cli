import Foundation

struct AppConfig: Codable, Sendable {
    var autoDiscoverPlugins: Bool = true
    var disabledPlugins: [String] = []
    /// Hook name → ordered plugin name list. Plugin names may include ":required" suffix (reserved for future use).
    var pipeline: [String: [String]] = [:]
    /// Plugin name → arbitrary key/value config passed to the plugin via stdin payload.
    var plugins: [String: [String: JSONValue]] = [:]
    /// Optional signing config retained for the `verify` command.
    var signing: SigningConfig?

    struct SigningConfig: Codable, Sendable {
        var xmpNamespace: String?
        var xmpPrefix: String = "piqley"
        static let defaultXmpPrefix = "piqley"
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case autoDiscoverPlugins, disabledPlugins, pipeline, plugins, signing
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoDiscoverPlugins = try container.decodeIfPresent(Bool.self, forKey: .autoDiscoverPlugins) ?? true
        disabledPlugins = try container.decodeIfPresent([String].self, forKey: .disabledPlugins) ?? []
        pipeline = try container.decodeIfPresent([String: [String]].self, forKey: .pipeline) ?? [:]
        plugins = try container.decodeIfPresent([String: [String: JSONValue]].self, forKey: .plugins) ?? [:]
        signing = try container.decodeIfPresent(SigningConfig.self, forKey: .signing)
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
