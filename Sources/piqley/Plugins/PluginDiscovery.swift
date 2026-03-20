import Foundation
import Logging
import PiqleyCore

enum PluginDiscoveryError: Error, LocalizedError {
    case invalidManifest(plugin: String, path: String, reasons: [String])
    case identifierMismatch(plugin: String, path: String, directoryName: String)
    case noStageFiles(plugin: String, path: String)

    var errorDescription: String? {
        switch self {
        case let .invalidManifest(plugin, path, reasons):
            "Plugin '\(plugin)' has invalid manifest: \(reasons.joined(separator: "; "))\n  at \(path)"
        case let .identifierMismatch(plugin, path, directoryName):
            "Plugin '\(plugin)': identifier does not match directory name '\(directoryName)'\n  at \(path)"
        case let .noStageFiles(plugin, path):
            "Plugin '\(plugin)' has no valid stage files\n  at \(path)"
        }
    }
}

struct LoadedPlugin: Sendable {
    /// The identity key (reverse TLD from manifest.identifier).
    let identifier: String
    /// Human-readable display name (from manifest.name).
    let name: String
    let directory: URL
    let manifest: PluginManifest
    let stages: [String: StageConfig]
}

struct PluginDiscovery: Sendable {
    let pluginsDirectory: URL
    private let logger = Logger(label: "piqley.discovery")

    func loadManifests() throws -> [LoadedPlugin] {
        guard FileManager.default.fileExists(atPath: pluginsDirectory.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        let knownHooks = Set(Hook.canonicalOrder.map(\.rawValue))

        return try contents.compactMap { url -> LoadedPlugin? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let dirName = url.lastPathComponent
            let manifestURL = url.appendingPathComponent(PluginFile.manifest)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

            let stages = Self.loadStages(from: url, knownHooks: knownHooks, logger: logger)

            // Validate manifest
            let validationErrors = ManifestValidator.validate(manifest)
            if !validationErrors.isEmpty {
                throw PluginDiscoveryError.invalidManifest(
                    plugin: manifest.identifier.isEmpty ? dirName : manifest.identifier,
                    path: url.path,
                    reasons: validationErrors
                )
            }

            // Verify identifier matches directory name
            if manifest.identifier != dirName {
                throw PluginDiscoveryError.identifierMismatch(
                    plugin: manifest.identifier,
                    path: url.path,
                    directoryName: dirName
                )
            }

            // Require at least one stage file
            if stages.isEmpty {
                throw PluginDiscoveryError.noStageFiles(
                    plugin: manifest.identifier,
                    path: url.path
                )
            }

            let dataDir = url.appendingPathComponent(PluginDirectory.data)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            return LoadedPlugin(identifier: manifest.identifier, name: manifest.name, directory: url, manifest: manifest, stages: stages)
        }.sorted { $0.identifier < $1.identifier }
    }

    static func loadStages(
        from pluginDir: URL, knownHooks: Set<String>,
        logger: Logger = Logger(label: "piqley.discovery")
    ) -> [String: StageConfig] {
        var stages: [String: StageConfig] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pluginDir, includingPropertiesForKeys: nil
        ) else { return stages }

        for file in files {
            let filename = file.lastPathComponent
            guard filename.hasPrefix(PluginFile.stagePrefix),
                  filename.hasSuffix(PluginFile.stageSuffix) else { continue }

            let stageName = String(
                filename.dropFirst(PluginFile.stagePrefix.count)
                    .dropLast(PluginFile.stageSuffix.count)
            )

            guard knownHooks.contains(stageName) else {
                logger.warning("Plugin '\(pluginDir.lastPathComponent)' has unknown stage '\(stageName)' — ignored")
                continue
            }

            do {
                let data = try Data(contentsOf: file)
                let config = try JSONDecoder().decode(StageConfig.self, from: data)
                if config.isEmpty {
                    logger.warning("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)' is empty — ignored")
                    continue
                }
                if let binary = config.binary, binary.batchProxy != nil {
                    if binary.pluginProtocol == .json {
                        logger.warning(
                            "Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)': batchProxy is not compatible with json protocol — skipped"
                        )
                        continue
                    }
                }
                stages[stageName] = config
            } catch {
                logger.warning("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)' has malformed JSON — skipped")
            }
        }

        return stages
    }
}
