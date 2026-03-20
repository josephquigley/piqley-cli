import Foundation
import Logging
import PiqleyCore

actor ForkManager {
    private let baseURL: URL
    private var forkPaths: [String: URL] = [:]
    private let logger = Logger(label: "piqley.fork")

    init(baseURL: URL) {
        self.baseURL = baseURL.appendingPathComponent("forks")
    }

    func getOrCreateFork(
        pluginId: String,
        sourceURL: URL,
        manifest: PluginManifest? = nil
    ) throws -> URL {
        if let existing = forkPaths[pluginId] {
            return existing
        }

        let forkURL = baseURL.appendingPathComponent(pluginId)
        try FileManager.default.createDirectory(at: forkURL, withIntermediateDirectories: true)

        let supportedFormats = manifest?.supportedFormats.map { Set($0) }
        let conversionFormat = manifest?.conversionFormat

        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let ext = file.pathExtension.lowercased()
            guard TempFolder.imageExtensions.contains(ext) else { continue }

            if let supported = supportedFormats, !supported.contains(ext) {
                if let target = conversionFormat {
                    let newName = (name as NSString).deletingPathExtension + "." + target
                    let destination = forkURL.appendingPathComponent(newName)
                    try ImageConverter.convert(from: file, to: destination, format: target)
                } else {
                    logger.warning("Skipping '\(name)' for plugin '\(pluginId)': unsupported format")
                }
            } else {
                let destination = forkURL.appendingPathComponent(name)
                try FileManager.default.copyItem(at: file, to: destination)
            }
        }

        forkPaths[pluginId] = forkURL
        return forkURL
    }

    func resolveSource(
        pluginId _: String,
        dependencies: [String],
        executedPlugins: [(hook: String, pluginId: String)],
        mainURL: URL
    ) -> URL {
        let executionOrder = executedPlugins.map(\.pluginId)
        var latestForkingDep: String?
        var latestIndex = -1

        for dep in dependencies {
            if forkPaths[dep] != nil,
               let idx = executionOrder.lastIndex(of: dep),
               idx > latestIndex
            {
                latestForkingDep = dep
                latestIndex = idx
            }
        }

        if let dep = latestForkingDep, let path = forkPaths[dep] {
            return path
        }
        return mainURL
    }

    func writeBack(pluginId: String, mainURL: URL) throws {
        guard let forkURL = forkPaths[pluginId] else { return }

        let contents = try FileManager.default.contentsOfDirectory(
            at: forkURL, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let destination = mainURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: file, to: destination)
        }
        logger.info("writeBack from '\(pluginId)' to main")
    }

    func hasFork(_ pluginId: String) -> Bool {
        forkPaths[pluginId] != nil
    }
}
