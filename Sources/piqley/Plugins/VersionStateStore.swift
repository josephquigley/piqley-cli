import Foundation
import PiqleyCore

protocol VersionStateStore: Sendable {
    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion?
    func save(version: SemanticVersion, for pluginIdentifier: String) throws
}

final class FileVersionStateStore: VersionStateStore, Sendable {
    private let pluginsDirectory: URL
    private let fileManager: any FileSystemManager

    init(pluginsDirectory: URL, fileManager: any FileSystemManager = FileManager.default) {
        self.pluginsDirectory = pluginsDirectory
        self.fileManager = fileManager
    }

    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion? {
        let fileURL = pluginsDirectory
            .appendingPathComponent(pluginIdentifier)
            .appendingPathComponent(PluginFile.versionState)
        guard let data = try? fileManager.contents(of: fileURL) else { return nil }
        return try? JSONDecoder.piqley.decode(VersionStateFile.self, from: data).lastExecutedVersion
    }

    func save(version: SemanticVersion, for pluginIdentifier: String) throws {
        let dir = pluginsDirectory.appendingPathComponent(pluginIdentifier)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = VersionStateFile(lastExecutedVersion: version)
        let data = try JSONEncoder.piqleyPrettyPrint.encode(file)
        try fileManager.write(data, to: dir.appendingPathComponent(PluginFile.versionState), options: .atomic)
    }
}

final class InMemoryVersionStateStore: VersionStateStore, @unchecked Sendable {
    private var versions: [String: SemanticVersion] = [:]
    private let lock = NSLock()

    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion? {
        lock.withLock { versions[pluginIdentifier] }
    }

    func save(version: SemanticVersion, for pluginIdentifier: String) throws {
        lock.withLock { versions[pluginIdentifier] = version }
    }
}

private struct VersionStateFile: Codable {
    let lastExecutedVersion: SemanticVersion
}
