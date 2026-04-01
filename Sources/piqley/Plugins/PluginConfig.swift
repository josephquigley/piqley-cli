import Foundation
import PiqleyCore

extension PluginConfig {
    static func load(from url: URL, fileManager: any FileSystemManager = FileManager.default) throws -> PluginConfig {
        let data = try fileManager.contents(of: url)
        return try JSONDecoder.piqley.decode(PluginConfig.self, from: data)
    }

    /// Loads from URL if the file exists, otherwise returns an empty config.
    static func load(fromIfExists url: URL, fileManager: any FileSystemManager = FileManager.default) -> PluginConfig {
        guard fileManager.fileExists(atPath: url.path) else { return PluginConfig() }
        return (try? load(from: url, fileManager: fileManager)) ?? PluginConfig()
    }

    func save(to url: URL, fileManager: any FileSystemManager = FileManager.default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.piqleyPrettyPrint.encode(self)
        try fileManager.write(data, to: url)
    }

    /// Returns a new PluginConfig with the given values dictionary.
    func withValues(_ values: [String: JSONValue]) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp)
    }

    /// Returns a new PluginConfig with a single value updated.
    func settingValue(_ value: JSONValue, forKey key: String) -> PluginConfig {
        var newValues = values
        newValues[key] = value
        return PluginConfig(values: newValues, isSetUp: isSetUp)
    }

    /// Returns a new PluginConfig with isSetUp set to the given value.
    func withIsSetUp(_ isSetUp: Bool?) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp)
    }
}
