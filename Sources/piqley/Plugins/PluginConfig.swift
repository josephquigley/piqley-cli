import Foundation
import PiqleyCore

extension PluginConfig {
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

    /// Returns a new PluginConfig with the given values dictionary.
    func withValues(_ values: [String: JSONValue]) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp, rules: rules)
    }

    /// Returns a new PluginConfig with a single value updated.
    func settingValue(_ value: JSONValue, forKey key: String) -> PluginConfig {
        var newValues = values
        newValues[key] = value
        return PluginConfig(values: newValues, isSetUp: isSetUp, rules: rules)
    }

    /// Returns a new PluginConfig with isSetUp set to the given value.
    func withIsSetUp(_ isSetUp: Bool?) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp, rules: rules)
    }

    /// Returns a new PluginConfig with the given rules.
    func withRules(_ rules: [Rule]) -> PluginConfig {
        PluginConfig(values: values, isSetUp: isSetUp, rules: rules)
    }
}
