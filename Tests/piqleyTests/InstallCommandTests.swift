import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("InstallCommand")
struct InstallCommandTests {

    /// Creates a test plugin zip archive in the given directory.
    /// Returns the URL of the created `.piqleyplugin` file.
    func createTestPlugin(
        name: String,
        protocolVersion: String = "1",
        in directory: URL,
        includeBin: Bool = false,
        includeManifest: Bool = true
    ) throws -> URL {
        let pluginDir = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        if includeManifest {
            let manifest = PluginManifest(
                identifier: name,
                name: name,
                pluginSchemaVersion: protocolVersion
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: pluginDir.appendingPathComponent(PluginFile.manifest))
        }

        if includeBin {
            let binDir = pluginDir.appendingPathComponent(PluginDirectory.bin)
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            let scriptURL = binDir.appendingPathComponent("run.sh")
            try "#!/bin/sh\necho hello".write(to: scriptURL, atomically: true, encoding: .utf8)
        }

        let zipURL = directory.appendingPathComponent("\(name).piqleyplugin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pluginDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw InstallError.extractionFailed
        }

        // Remove the source directory so install can be tested cleanly
        try FileManager.default.removeItem(at: pluginDir)

        return zipURL
    }

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("installs valid plugin")
    func installsValidPlugin() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "test-plugin", in: tmpDir)
        let installDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        try PluginInstaller.install(from: zipURL, to: installDir)

        let pluginPath = installDir.appendingPathComponent("test-plugin")
        #expect(FileManager.default.fileExists(atPath: pluginPath.path))
        #expect(FileManager.default.fileExists(atPath: pluginPath.appendingPathComponent(PluginFile.manifest).path))
        #expect(FileManager.default.fileExists(atPath: pluginPath.appendingPathComponent(PluginDirectory.logs).path))
        #expect(FileManager.default.fileExists(atPath: pluginPath.appendingPathComponent(PluginDirectory.data).path))
    }

    @Test("rejects unsupported protocol version")
    func rejectsUnsupportedProtocolVersion() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "bad-version", protocolVersion: "99", in: tmpDir)
        let installDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: zipURL, to: installDir)
        }
    }

    @Test("rejects missing manifest")
    func rejectsMissingManifest() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "no-manifest", in: tmpDir, includeManifest: false)
        let installDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: zipURL, to: installDir)
        }
    }

    @Test("sets executable permissions on bin files")
    func setsExecutablePermissions() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "bin-plugin", in: tmpDir, includeBin: true)
        let installDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        try PluginInstaller.install(from: zipURL, to: installDir)

        let scriptPath = installDir
            .appendingPathComponent("bin-plugin")
            .appendingPathComponent(PluginDirectory.bin)
            .appendingPathComponent("run.sh")
        #expect(FileManager.default.fileExists(atPath: scriptPath.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(permissions & 0o111 != 0, "bin files should have executable permission")
    }

    @Test("rejects unsupported platform")
    func installRejectsUnsupportedPlatform() throws {
        let fm = FileManager.default
        let tmpDir = try makeTempDir()
        defer { try? fm.removeItem(at: tmpDir) }

        // Create a plugin zip that only supports a different platform
        let pluginDir = tmpDir.appendingPathComponent("unsupported-plugin")
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "identifier": "com.test.unsupported",
            "name": "unsupported",
            "pluginSchemaVersion": "2",
            "supportedPlatforms": ["linux-amd64"],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))

        // Create a minimal stage file
        try Data("{}".utf8).write(to: pluginDir.appendingPathComponent("stage-process.json"))

        // Zip using ditto (same as existing helper)
        let zipURL = tmpDir.appendingPathComponent("unsupported.piqleyplugin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pluginDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.extractionFailed
        }

        let installDir = tmpDir.appendingPathComponent("plugins")
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: zipURL, to: installDir)
        }
    }

    @Test("flattens platform directories on install")
    func installFlattensPlatformDirectories() throws {
        let fm = FileManager.default
        let tmpDir = try makeTempDir()
        defer { try? fm.removeItem(at: tmpDir) }

        // Create a plugin zip with platform subdirectories
        let pluginDir = tmpDir.appendingPathComponent("multi-plugin")
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "identifier": "com.test.multi",
            "name": "multi",
            "pluginSchemaVersion": "2",
            "supportedPlatforms": [HostPlatform.current, "linux-amd64"],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: pluginDir.appendingPathComponent("stage-process.json"))

        // Create platform bin directories
        let hostBinDir = pluginDir.appendingPathComponent("bin/\(HostPlatform.current)")
        let otherBinDir = pluginDir.appendingPathComponent("bin/linux-amd64")
        try fm.createDirectory(at: hostBinDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherBinDir, withIntermediateDirectories: true)
        try Data("host-binary".utf8).write(to: hostBinDir.appendingPathComponent("my-plugin"))
        try Data("other-binary".utf8).write(to: otherBinDir.appendingPathComponent("my-plugin"))

        // Zip using ditto
        let zipURL = tmpDir.appendingPathComponent("multi.piqleyplugin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pluginDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.extractionFailed
        }

        let installDir = tmpDir.appendingPathComponent("plugins")
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        try PluginInstaller.install(from: zipURL, to: installDir)

        let installLocation = installDir.appendingPathComponent("com.test.multi")
        // Binary should be flat in bin/, not in a platform subdirectory
        #expect(fm.fileExists(atPath: installLocation.appendingPathComponent("bin/my-plugin").path))
        #expect(!fm.fileExists(atPath: installLocation.appendingPathComponent("bin/\(HostPlatform.current)").path))
        #expect(!fm.fileExists(atPath: installLocation.appendingPathComponent("bin/linux-amd64").path))
    }

    @Test("rejects corrupted zip")
    func rejectsCorruptedZip() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let corruptedURL = tmpDir.appendingPathComponent("corrupt.piqleyplugin")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF]).write(to: corruptedURL)

        let installDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: corruptedURL, to: installDir)
        }
    }
}
