import ArgumentParser
import Foundation
import PiqleyCore

enum InstallError: Error, CustomStringConvertible {
    case fileNotFound
    case notAPiqleyPlugin
    case missingManifest
    case invalidManifest
    case unsupportedSchemaVersion
    case alreadyInstalled
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
        case .alreadyInstalled:
            "Plugin is already installed. Use --force to overwrite."
        case let .unsupportedPlatform(host, supported):
            "This plugin does not support \(host). Supported platforms: \(supported.joined(separator: ", "))"
        case .extractionFailed:
            "Failed to extract plugin archive."
        }
    }
}

enum PluginInstaller {
    @discardableResult
    static func install(from zipURL: URL, to pluginsDirectory: URL, force: Bool = false) throws -> String {
        let fileManager = FileManager.default

        // 1. Extract zip to temp dir
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("piqley-install-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, tempDir.path]
        try ditto.run()
        ditto.waitUntilExit()

        guard ditto.terminationStatus == 0 else {
            throw InstallError.extractionFailed
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
            throw InstallError.extractionFailed
        }

        // 3. Read and decode manifest.json
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw InstallError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        } catch {
            throw InstallError.invalidManifest
        }

        // 4. Validate schema version
        guard PluginManifest.supportedSchemaVersions.contains(manifest.pluginSchemaVersion) else {
            throw InstallError.unsupportedSchemaVersion
        }

        // 5. Run ManifestValidator
        let errors = ManifestValidator.validate(manifest)
        if !errors.isEmpty {
            throw InstallError.invalidManifest
        }

        // 6. Check platform support
        if let supportedPlatforms = manifest.supportedPlatforms {
            guard supportedPlatforms.contains(HostPlatform.current) else {
                throw InstallError.unsupportedPlatform(
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

        // 8. Check if already installed
        let installLocation = pluginsDirectory.appendingPathComponent(manifest.identifier)
        if fileManager.fileExists(atPath: installLocation.path) {
            if force {
                try fileManager.removeItem(at: installLocation)
            } else {
                throw InstallError.alreadyInstalled
            }
        }

        // 9. Move plugin dir to install location
        try fileManager.moveItem(at: pluginDir, to: installLocation)

        // 10. Set executable permissions on all files in bin/
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

        // 11. Create logs/ and data/ directories if not present
        let logsDir = installLocation.appendingPathComponent(PluginDirectory.logs)
        if !fileManager.fileExists(atPath: logsDir.path) {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        let dataDir = installLocation.appendingPathComponent(PluginDirectory.data)
        if !fileManager.fileExists(atPath: dataDir.path) {
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }

        return manifest.identifier
    }
}

struct InstallSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a .piqleyplugin package"
    )

    @Argument(help: "Path to the .piqleyplugin file")
    var pluginFile: String

    @Flag(help: "Overwrite existing plugin if already installed")
    var force = false

    func validate() throws {
        guard FileManager.default.fileExists(atPath: pluginFile) else {
            throw InstallError.fileNotFound
        }
        guard pluginFile.hasSuffix(".piqleyplugin") else {
            throw InstallError.notAPiqleyPlugin
        }
    }

    func run() throws {
        let zipURL = URL(fileURLWithPath: pluginFile)
        let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let identifier = try PluginInstaller.install(from: zipURL, to: pluginsDir, force: force)

        print("Plugin installed successfully.")

        // Run config/secret setup if the manifest declares any
        let (_, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()
        guard let plugin = allPlugins.first(where: { $0.identifier == identifier }) else { return }
        guard !plugin.manifest.config.isEmpty else { return }

        print("\nRunning setup for '\(plugin.name)'...\n")
        let secretStore = makeDefaultSecretStore()
        var scanner = PluginSetupScanner(
            secretStore: secretStore,
            inputSource: StdinInputSource()
        )
        try scanner.scan(plugin: plugin)
        print("\nSetup complete.")
    }
}
