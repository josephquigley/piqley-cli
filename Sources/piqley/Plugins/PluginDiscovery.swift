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
    let registry: StageRegistry
    let fileManager: any FileSystemManager
    private let logger = Logger(label: "piqley.discovery")

    init(pluginsDirectory: URL, registry: StageRegistry, fileManager: any FileSystemManager = FileManager.default) {
        self.pluginsDirectory = pluginsDirectory
        self.registry = registry
        self.fileManager = fileManager
    }

    func loadManifests() throws -> (plugins: [LoadedPlugin], registry: StageRegistry) {
        var updatedRegistry = registry
        guard fileManager.fileExists(atPath: pluginsDirectory.path) else { return ([], updatedRegistry) }

        let contents = try fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        let knownHooks = updatedRegistry.allKnownNames

        let plugins: [LoadedPlugin] = try contents.compactMap { url -> LoadedPlugin? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let dirName = url.lastPathComponent
            let manifestURL = url.appendingPathComponent(PluginFile.manifest)
            guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try fileManager.contents(of: manifestURL)
            let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: data)

            let (stages, newStageNames) = Self.loadStages(from: url, knownHooks: knownHooks, fileManager: fileManager, logger: logger)
            for name in newStageNames {
                updatedRegistry.autoRegister(name)
            }

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

            let dataDir = url.appendingPathComponent(PluginDirectory.data)
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
            return LoadedPlugin(identifier: manifest.identifier, name: manifest.name, directory: url, manifest: manifest, stages: stages)
        }.sorted { $0.identifier < $1.identifier }

        return (plugins, updatedRegistry)
    }

    /// Tracks which plugin+stage combos have already emitted a regex sanitizer warning.
    private nonisolated(unsafe) static var regexSanitizerWarned: Set<String> = []

    static func loadStages(
        from pluginDir: URL, knownHooks: Set<String>,
        fileManager: any FileSystemManager = FileManager.default,
        logger: Logger = Logger(label: "piqley.discovery")
    ) -> (stages: [String: StageConfig], newStageNames: Set<String>) {
        var stages: [String: StageConfig] = [:]
        var newStageNames: Set<String> = []

        guard let files = try? fileManager.contentsOfDirectory(
            at: pluginDir, includingPropertiesForKeys: nil
        ) else { return (stages, newStageNames) }

        for file in files {
            let filename = file.lastPathComponent
            guard filename.hasPrefix(PluginFile.stagePrefix),
                  filename.hasSuffix(PluginFile.stageSuffix) else { continue }

            let stageName = String(
                filename.dropFirst(PluginFile.stagePrefix.count)
                    .dropLast(PluginFile.stageSuffix.count)
            )

            if !knownHooks.contains(stageName) {
                newStageNames.insert(stageName)
            }

            do {
                let data = try fileManager.contents(of: file)
                let config = try JSONDecoder.piqley.decode(StageConfig.self, from: data)
                if config.isEffectivelyEmpty {
                    logger.debug("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)' is empty — ignored")
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
                let (sanitized, didFix) = RegexSanitizer.sanitizeStageConfig(config)
                if didFix {
                    let plugin = pluginDir.lastPathComponent
                    let warnKey = "\(plugin):\(stageName)"
                    if !regexSanitizerWarned.contains(warnKey) {
                        regexSanitizerWarned.insert(warnKey)
                        let workflows = findWorkflowsWithBadRegex(
                            plugin: plugin, stageName: stageName, fileManager: fileManager
                        )
                        if workflows.isEmpty {
                            logger.warning(
                                "Plugin '\(plugin)' stage '\(stageName)': fixed double-escaped regex patterns. Re-save this stage to persist the fix."
                            )
                        } else {
                            let list = workflows.joined(separator: ", ")
                            // swiftlint:disable:next line_length
                            logger.warning("Plugin '\(plugin)' stage '\(stageName)': fixed double-escaped regex patterns. Re-save this stage in the following workflow(s) to persist the fix: \(list)")
                        }
                    }
                }
                stages[stageName] = sanitized
            } catch {
                logger.warning("Plugin '\(pluginDir.lastPathComponent)' stage '\(stageName)' has malformed JSON — skipped")
            }
        }

        return (stages, newStageNames)
    }

    /// Returns sorted workflow names that have bad regex patterns for the given plugin and stage.
    private static func findWorkflowsWithBadRegex(
        plugin: String, stageName: String,
        fileManager: any FileSystemManager = FileManager.default
    ) -> [String] {
        guard let workflows = try? WorkflowStore.list(fileManager: fileManager) else { return [] }
        let stageFilename = "\(PluginFile.stagePrefix)\(stageName)\(PluginFile.stageSuffix)"
        var affected: [String] = []
        for workflow in workflows {
            let stageFile = WorkflowStore.pluginRulesDirectory(
                workflowName: workflow, pluginIdentifier: plugin
            ).appendingPathComponent(stageFilename)
            guard let data = try? fileManager.contents(of: stageFile),
                  let config = try? JSONDecoder.piqley.decode(StageConfig.self, from: data)
            else {
                continue
            }
            let (_, hasBadRegex) = RegexSanitizer.sanitizeStageConfig(config)
            if hasBadRegex {
                affected.append(workflow)
            }
        }
        return affected.sorted()
    }
}
