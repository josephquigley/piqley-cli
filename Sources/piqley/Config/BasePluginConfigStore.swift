import Foundation

struct BasePluginConfigStore: Sendable {
    let directory: URL

    func save(_ config: BasePluginConfig, for pluginIdentifier: String) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL(for: pluginIdentifier), options: .atomic)
    }

    func load(for pluginIdentifier: String) throws -> BasePluginConfig? {
        let url = fileURL(for: pluginIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BasePluginConfig.self, from: data)
    }

    func delete(for pluginIdentifier: String) throws {
        let url = fileURL(for: pluginIdentifier)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for pluginIdentifier: String) -> URL {
        directory.appendingPathComponent("\(pluginIdentifier).json")
    }
}
