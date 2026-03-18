import Foundation

/// Per-plugin mutable configuration sidecar (`config.json`).
struct PluginConfig: Codable, Sendable {
    var values: [String: JSONValue] = [:]
    var isSetUp: Bool?

    init() {}

    static func load(from url: URL) throws -> PluginConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginConfig.self, from: data)
    }

    /// Loads from URL if the file exists, otherwise returns an empty config.
    static func load(fromIfExists url: URL) -> PluginConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return PluginConfig() }
        return (try? load(from: url)) ?? PluginConfig()
    }

    func save(to url: URL) throws {
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
