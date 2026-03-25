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
            "Plugin '\(identifier)' is not installed. Use 'piqley plugin install' first."
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
        let tempBinDir = pluginDir.appendingPathComponent(PluginDirectory.bin)
        if fileManager.fileExists(atPath: tempBinDir.path) {
            let platformBinDir = tempBinDir.appendingPathComponent(HostPlatform.current)
            if fileManager.fileExists(atPath: platformBinDir.path) {
                let platformFiles = try fileManager.contentsOfDirectory(
                    at: platformBinDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for file in platformFiles {
                    let dst = tempBinDir.appendingPathComponent(file.lastPathComponent)
                    try fileManager.moveItem(at: file, to: dst)
                }
                let binContents = try fileManager.contentsOfDirectory(
                    at: tempBinDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for item in binContents
                    where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                {
                    try fileManager.removeItem(at: item)
                }
            }
        }

        let tempDataDir = pluginDir.appendingPathComponent(PluginDirectory.data)
        if fileManager.fileExists(atPath: tempDataDir.path) {
            let platformDataDir = tempDataDir.appendingPathComponent(HostPlatform.current)
            if fileManager.fileExists(atPath: platformDataDir.path) {
                let platformFiles = try fileManager.contentsOfDirectory(
                    at: platformDataDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for file in platformFiles {
                    let dst = tempDataDir.appendingPathComponent(file.lastPathComponent)
                    try fileManager.moveItem(at: file, to: dst)
                }
                let dataContents = try fileManager.contentsOfDirectory(
                    at: tempDataDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for item in dataContents
                    where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                {
                    try fileManager.removeItem(at: item)
                }
            }
        }

        // 8. Verify plugin is installed (derive identity from zip's manifest)
        let installLocation = pluginsDirectory.appendingPathComponent(newManifest.identifier)
        guard fileManager.fileExists(atPath: installLocation.path) else {
            throw UpdateError.notInstalled(identifier: newManifest.identifier)
        }

        // 9. Read old manifest from installed directory
        let oldManifestURL = installLocation.appendingPathComponent(PluginFile.manifest)
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
}
