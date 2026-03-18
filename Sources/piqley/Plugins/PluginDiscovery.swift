import Foundation
import Logging
import PiqleyCore

struct LoadedPlugin: Sendable {
    let name: String
    let directory: URL
    let manifest: PluginManifest
}

struct PluginDiscovery: Sendable {
    let pluginsDirectory: URL
    private let logger = Logger(label: "piqley.discovery")

    /// Loads all plugin manifests from `pluginsDirectory`, skipping disabled plugins and
    /// directories without a `manifest.json`.
    func loadManifests(disabled: [String]) throws -> [LoadedPlugin] {
        guard FileManager.default.fileExists(atPath: pluginsDirectory.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return try contents.compactMap { url -> LoadedPlugin? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            guard !disabled.contains(name) else { return nil }
            let manifestURL = url.appendingPathComponent(PluginFile.manifest)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            // Warn about unknown hook names
            for unknown in manifest.unknownHooks() {
                logger.warning("Plugin '\(name)' declares unknown hook '\(unknown)' — ignored")
            }
            let dataDir = url.appendingPathComponent(PluginDirectory.data)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            return LoadedPlugin(name: name, directory: url, manifest: manifest)
        }.sorted { $0.name < $1.name }
    }

    /// Appends newly discovered plugins to pipeline hook lists.
    /// Plugins already listed (by name, ignoring any suffixes) are not duplicated.
    /// Only adds to hooks the plugin actually declares.
    static func autoAppend(discovered: [LoadedPlugin], into pipeline: inout [String: [String]]) {
        for plugin in discovered {
            for hookName in Hook.canonicalOrder.map(\.rawValue) {
                guard plugin.manifest.hooks[hookName] != nil else { continue }
                var list = pipeline[hookName] ?? []
                // Check if plugin name (without any suffix) is already listed
                let alreadyListed = list.contains { entry in
                    entry == plugin.name || entry.hasPrefix(plugin.name + ":")
                }
                guard !alreadyListed else { continue }
                list.append(plugin.name)
                pipeline[hookName] = list
            }
        }
    }
}
