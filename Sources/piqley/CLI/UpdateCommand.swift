import ArgumentParser
import Foundation
import PiqleyCore

enum UpdateError: Error, CustomStringConvertible, Equatable {
    case fileNotFound
    case notAPiqleyPlugin
    case missingManifest
    case invalidManifest
    case unsupportedSchemaVersion
    case notInstalled(identifier: String)
    case unsupportedPlatform(host: String, supported: [String])
    case extractionFailed

    var description: String {
        switch self {
        case .fileNotFound:
            "Plugin file not found."
        case .notAPiqleyPlugin:
            "File does not have a .piqleyplugin extension."
        case .missingManifest:
            "Plugin archive does not contain a manifest.json."
        case .invalidManifest:
            "Plugin manifest is invalid."
        case .unsupportedSchemaVersion:
            "Plugin schema version is not supported."
        case let .notInstalled(identifier):
            "Plugin '\(identifier)' is not installed. Use 'piqley plugin install' instead."
        case let .unsupportedPlatform(host, supported):
            "This plugin does not support \(host). Supported platforms: \(supported.joined(separator: ", "))"
        case .extractionFailed:
            "Failed to extract plugin archive."
        }
    }
}

struct UpdateResult {
    let identifier: String
    let oldManifest: PluginManifest
    let newManifest: PluginManifest
}

struct ConfigMergeResult {
    var mergedConfig: BasePluginConfig
    var skipValueKeys: Set<String>
    var skipSecretKeys: Set<String>
    var removedValueKeys: Set<String>
    var removedSecretKeys: Set<String>
    /// Maps key -> (oldType, newType) for entries whose type changed.
    var typeChangedKeys: [String: (ConfigValueType, ConfigValueType)]
}

enum ConfigMerger {
    static func merge(
        oldManifest: PluginManifest,
        newManifest: PluginManifest,
        existingConfig: BasePluginConfig
    ) -> ConfigMergeResult {
        // Build keyed lookups from old manifest
        var oldValueTypes: [String: ConfigValueType] = [:]
        var oldSecretTypes: [String: ConfigValueType] = [:]
        for entry in oldManifest.config {
            switch entry {
            case let .value(key, type, _, _): oldValueTypes[key] = type
            case let .secret(secretKey, type, _): oldSecretTypes[secretKey] = type
            }
        }

        // Build keyed lookups from new manifest
        var newValueTypes: [String: ConfigValueType] = [:]
        var newSecretKeys = Set<String>()
        for entry in newManifest.config {
            switch entry {
            case let .value(key, type, _, _): newValueTypes[key] = type
            case let .secret(secretKey, _, _): newSecretKeys.insert(secretKey)
            }
        }

        var mergedConfig = existingConfig
        var skipValueKeys = Set<String>()
        var skipSecretKeys = Set<String>()
        var removedValueKeys = Set<String>()
        var removedSecretKeys = Set<String>()
        var typeChangedKeys: [String: (ConfigValueType, ConfigValueType)] = [:]

        // Process value entries in new manifest
        for (key, newType) in newValueTypes {
            if let oldType = oldValueTypes[key] {
                if oldType == newType, mergedConfig.values[key] != nil {
                    skipValueKeys.insert(key)
                } else if oldType != newType {
                    mergedConfig.values.removeValue(forKey: key)
                    typeChangedKeys[key] = (oldType, newType)
                }
            }
        }

        // Process secret entries in new manifest
        for secretKey in newSecretKeys {
            if oldSecretTypes[secretKey] != nil, mergedConfig.secrets[secretKey] != nil {
                skipSecretKeys.insert(secretKey)
            }
        }

        // Find removed value keys
        for key in oldValueTypes.keys where newValueTypes[key] == nil {
            mergedConfig.values.removeValue(forKey: key)
            removedValueKeys.insert(key)
        }

        // Find removed secret keys
        for key in oldSecretTypes.keys where !newSecretKeys.contains(key) {
            mergedConfig.secrets.removeValue(forKey: key)
            removedSecretKeys.insert(key)
        }

        // Reset isSetUp so setup binary re-runs
        mergedConfig.isSetUp = nil

        return ConfigMergeResult(
            mergedConfig: mergedConfig,
            skipValueKeys: skipValueKeys,
            skipSecretKeys: skipSecretKeys,
            removedValueKeys: removedValueKeys,
            removedSecretKeys: removedSecretKeys,
            typeChangedKeys: typeChangedKeys
        )
    }
}

enum PluginUpdater {
    @discardableResult
    static func update(from zipURL: URL, pluginsDirectory: URL) throws -> UpdateResult {
        let fileManager = FileManager.default

        // 1. Extract zip to temp dir
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("piqley-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, tempDir.path]
        try ditto.run()
        ditto.waitUntilExit()

        guard ditto.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        // 2. Find plugin directory (first directory in extracted contents)
        let contents = try fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let pluginDir = contents.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) else {
            throw UpdateError.extractionFailed
        }

        // 3. Read and decode manifest.json
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw UpdateError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let newManifest: PluginManifest
        do {
            newManifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: manifestData)
        } catch {
            throw UpdateError.invalidManifest
        }

        // 4. Validate schema version
        guard PluginManifest.supportedSchemaVersions.contains(newManifest.pluginSchemaVersion) else {
            throw UpdateError.unsupportedSchemaVersion
        }

        // 5. Run ManifestValidator
        let errors = ManifestValidator.validate(newManifest)
        if !errors.isEmpty {
            throw UpdateError.invalidManifest
        }

        // 6. Check platform support
        if let supportedPlatforms = newManifest.supportedPlatforms {
            guard supportedPlatforms.contains(HostPlatform.current) else {
                throw UpdateError.unsupportedPlatform(
                    host: HostPlatform.current,
                    supported: supportedPlatforms
                )
            }
        }

        // 7. Flatten platform-specific bin/ and data/ directories in temp
        try flattenPlatformDirectory(pluginDir.appendingPathComponent(PluginDirectory.bin))
        try flattenPlatformDirectory(pluginDir.appendingPathComponent(PluginDirectory.data))

        // 8. Verify plugin is installed (derive identity from zip's manifest)
        let installLocation = pluginsDirectory.appendingPathComponent(newManifest.identifier)
        guard fileManager.fileExists(atPath: installLocation.path) else {
            throw UpdateError.notInstalled(identifier: newManifest.identifier)
        }

        // 9. Read old manifest from installed directory
        let oldManifestURL = installLocation.appendingPathComponent(PluginFile.manifest)
        guard fileManager.fileExists(atPath: oldManifestURL.path) else {
            throw UpdateError.missingManifest
        }
        let oldManifestData = try Data(contentsOf: oldManifestURL)
        let oldManifest: PluginManifest
        do {
            oldManifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: oldManifestData)
        } catch {
            throw UpdateError.invalidManifest
        }

        // 10. Delete old and move new
        try fileManager.removeItem(at: installLocation)
        try fileManager.moveItem(at: pluginDir, to: installLocation)

        // 11. Write installedPlatform to manifest
        let installedManifestURL = installLocation.appendingPathComponent(PluginFile.manifest)
        let rawManifestData = try Data(contentsOf: installedManifestURL)
        var manifestDict =
            try JSONSerialization.jsonObject(with: rawManifestData) as? [String: Any] ?? [:]
        manifestDict["installedPlatform"] = HostPlatform.current
        let updatedManifestData = try JSONSerialization.data(
            withJSONObject: manifestDict, options: [.prettyPrinted, .sortedKeys]
        )
        try updatedManifestData.write(to: installedManifestURL, options: .atomic)

        // 12. Set executable permissions on all files in bin/
        let binDir = installLocation.appendingPathComponent(PluginDirectory.bin)
        if fileManager.fileExists(atPath: binDir.path) {
            let binFiles = try fileManager.contentsOfDirectory(
                at: binDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in binFiles {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                process.arguments = ["+x", file.path]
                try process.run()
                process.waitUntilExit()
            }
        }

        // 13. Create logs/ and data/ directories if not present
        let logsDir = installLocation.appendingPathComponent(PluginDirectory.logs)
        if !fileManager.fileExists(atPath: logsDir.path) {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        let dataDir = installLocation.appendingPathComponent(PluginDirectory.data)
        if !fileManager.fileExists(atPath: dataDir.path) {
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }

        return UpdateResult(
            identifier: newManifest.identifier,
            oldManifest: oldManifest,
            newManifest: newManifest
        )
    }

    /// Moves platform-specific files from `{dir}/{platform}/` up to `{dir}/` and removes
    /// any remaining subdirectories. No-op if the directory does not exist.
    private static func flattenPlatformDirectory(_ dir: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dir.path) else { return }
        let platformDir = dir.appendingPathComponent(HostPlatform.current)
        guard fileManager.fileExists(atPath: platformDir.path) else { return }

        let platformFiles = try fileManager.contentsOfDirectory(
            at: platformDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        for file in platformFiles {
            try fileManager.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        let remaining = try fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        for item in remaining
            where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        {
            try fileManager.removeItem(at: item)
        }
    }
}

struct UpdateSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an installed plugin from a .piqleyplugin package"
    )

    @Argument(help: "Path to a .piqleyplugin file, URL to download one, or a git repo URL")
    var pluginSource: String

    func validate() throws {
        switch PluginFetcher.sourceKind(pluginSource) {
        case .url, .gitRepo:
            return
        case .file:
            guard FileManager.default.fileExists(atPath: pluginSource) else {
                throw UpdateError.fileNotFound
            }
            guard pluginSource.hasSuffix(".piqleyplugin") else {
                throw UpdateError.notAPiqleyPlugin
            }
        }
    }

    func run() throws {
        let zipURL: URL
        var fetchTempDir: URL?

        switch PluginFetcher.sourceKind(pluginSource) {
        case .url:
            print("Downloading plugin...")
            let result = try PluginFetcher.download(from: pluginSource)
            zipURL = result.fileURL
            fetchTempDir = result.tempDir
        case .gitRepo:
            print("Cloning repository...")
            let result = try PluginFetcher.cloneAndPackage(from: pluginSource)
            zipURL = result.fileURL
            fetchTempDir = result.tempDir
        case .file:
            zipURL = URL(fileURLWithPath: pluginSource)
        }
        defer { if let dir = fetchTempDir { try? FileManager.default.removeItem(at: dir) } }

        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

        let result = try PluginUpdater.update(from: zipURL, pluginsDirectory: pluginsDir)

        // Print version transition
        if let oldVersion = result.oldManifest.pluginVersion,
           let newVersion = result.newManifest.pluginVersion
        {
            print("Updating \(result.identifier) from \(oldVersion) to \(newVersion)")
        }
        print("Plugin files updated successfully.")

        // Load existing config
        let configStore = BasePluginConfigStore.default
        let existingConfig = (try? configStore.load(for: result.identifier)) ?? BasePluginConfig()

        // Merge configs
        let mergeResult = ConfigMerger.merge(
            oldManifest: result.oldManifest,
            newManifest: result.newManifest,
            existingConfig: existingConfig
        )

        // Build display label lookups from manifests
        let newLabels = Self.displayLabels(from: result.newManifest)
        let oldLabels = Self.displayLabels(from: result.oldManifest)

        // Print kept entries
        for key in mergeResult.skipValueKeys.sorted() {
            if let value = mergeResult.mergedConfig.values[key] {
                let label = newLabels[key] ?? key
                print("Kept config '\(label)' = \(displayValue(value))")
            }
        }
        for key in mergeResult.skipSecretKeys.sorted() {
            let label = newLabels[key] ?? key
            print("Kept secret '\(label)'")
        }

        // Print removed entries
        for key in mergeResult.removedValueKeys.sorted() {
            let label = oldLabels[key] ?? key
            print("Removed config '\(label)' (no longer in manifest).")
        }
        for key in mergeResult.removedSecretKeys.sorted() {
            let label = oldLabels[key] ?? key
            print("Removed secret '\(label)' (no longer in manifest).")
        }

        // Print type changes
        for (key, (oldType, newType)) in mergeResult.typeChangedKeys.sorted(by: { $0.key < $1.key }) {
            let label = newLabels[key] ?? key
            print("Config '\(label)' type changed from \(oldType.rawValue) to \(newType.rawValue), re-prompting.")
        }

        // Save merged config before scan so scanner picks it up
        try configStore.save(mergeResult.mergedConfig, for: result.identifier)

        let secretStore = makeDefaultSecretStore()

        // Run scanner for new/changed entries + setup binary
        guard !result.newManifest.config.isEmpty || result.newManifest.setup != nil else {
            let pruned = try SecretPruner.prune(configStore: configStore, secretStore: secretStore)
            if !pruned.isEmpty {
                print("Pruned \(pruned.count) orphaned secret(s).")
            }
            print("\nUpdate complete.")
            return
        }

        let (_, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()
        guard let plugin = allPlugins.first(where: { $0.identifier == result.identifier }) else {
            print("\nUpdate complete.")
            return
        }

        print("\nRunning setup for '\(plugin.name)'...\n")
        var scanner = PluginSetupScanner(
            secretStore: secretStore,
            configStore: configStore,
            inputSource: StdinInputSource()
        )
        try scanner.scan(
            plugin: plugin,
            skipValueKeys: mergeResult.skipValueKeys,
            skipSecretKeys: mergeResult.skipSecretKeys
        )

        // Prune orphaned secrets
        let pruned = try SecretPruner.prune(configStore: configStore, secretStore: secretStore)
        if !pruned.isEmpty {
            print("Pruned \(pruned.count) orphaned secret(s).")
        }

        print("\nUpdate complete.")
    }

    private func displayValue(_ value: JSONValue) -> String {
        switch value {
        case let .string(str): str
        case let .number(num):
            if num.truncatingRemainder(dividingBy: 1) == 0 {
                String(Int(num))
            } else {
                String(num)
            }
        case let .bool(flag): String(flag)
        default: ""
        }
    }

    /// Build a dictionary mapping each config key to its display label.
    private static func displayLabels(from manifest: PluginManifest) -> [String: String] {
        var labels: [String: String] = [:]
        for entry in manifest.config {
            switch entry {
            case let .value(key, _, _, _):
                labels[key] = entry.displayLabel
            case let .secret(secretKey, _, _):
                labels[secretKey] = entry.displayLabel
            }
        }
        return labels
    }
}
