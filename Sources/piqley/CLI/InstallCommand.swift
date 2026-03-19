import ArgumentParser
import Foundation
import PiqleyCore

enum InstallError: Error, CustomStringConvertible {
    case fileNotFound
    case notAPiqleyPlugin
    case missingManifest
    case invalidManifest
    case unsupportedProtocolVersion
    case alreadyInstalled
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
        case .unsupportedProtocolVersion:
            "Plugin protocol version is not supported."
        case .alreadyInstalled:
            "Plugin is already installed. Use --force to overwrite."
        case .extractionFailed:
            "Failed to extract plugin archive."
        }
    }
}

enum PluginInstaller {
    static let supportedProtocolVersions: Set<String> = ["1"]

    static func install(from zipURL: URL, to pluginsDirectory: URL, force: Bool = false) throws {
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

        // 4. Validate protocol version
        guard supportedProtocolVersions.contains(manifest.pluginProtocolVersion) else {
            throw InstallError.unsupportedProtocolVersion
        }

        // 5. Run ManifestValidator
        let errors = ManifestValidator.validate(manifest)
        if !errors.isEmpty {
            throw InstallError.invalidManifest
        }

        // 6. Check if already installed
        let installLocation = pluginsDirectory.appendingPathComponent(manifest.identifier)
        if fileManager.fileExists(atPath: installLocation.path) {
            if force {
                try fileManager.removeItem(at: installLocation)
            } else {
                throw InstallError.alreadyInstalled
            }
        }

        // 7. Move plugin dir to install location
        try fileManager.moveItem(at: pluginDir, to: installLocation)

        // 8. Set executable permissions on all files in bin/
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

        // 9. Create logs/ and data/ directories if not present
        let logsDir = installLocation.appendingPathComponent(PluginDirectory.logs)
        if !fileManager.fileExists(atPath: logsDir.path) {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        let dataDir = installLocation.appendingPathComponent(PluginDirectory.data)
        if !fileManager.fileExists(atPath: dataDir.path) {
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }
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
        try PluginInstaller.install(from: zipURL, to: pluginsDir, force: force)

        print("Plugin installed successfully.")
    }
}
