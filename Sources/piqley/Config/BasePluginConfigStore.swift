import Foundation
import PiqleyCore

struct BasePluginConfigStore: Sendable {
    let directory: URL
    let fileManager: any FileSystemManager

    /// Default store at `~/.config/piqley/config/`.
    static var `default`: BasePluginConfigStore {
        BasePluginConfigStore(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(PiqleyPath.config),
            fileManager: FileManager.default
        )
    }

    func save(_ config: BasePluginConfig, for pluginIdentifier: String) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.piqleyPrettyPrint.encode(config)
        try fileManager.write(data, to: fileURL(for: pluginIdentifier), options: .atomic)
    }

    func load(for pluginIdentifier: String) throws -> BasePluginConfig? {
        let url = fileURL(for: pluginIdentifier)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try fileManager.contents(of: url)
        return try JSONDecoder.piqley.decode(BasePluginConfig.self, from: data)
    }

    func delete(for pluginIdentifier: String) throws {
        let url = fileURL(for: pluginIdentifier)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(for pluginIdentifier: String) -> URL {
        directory.appendingPathComponent("\(pluginIdentifier).json")
    }
}
