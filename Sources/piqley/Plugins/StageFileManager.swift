import Foundation
import PiqleyCore

enum StageFileManager {
    /// Save stage configs to disk. Effectively empty stages are not written;
    /// existing empty stage files are removed.
    static func saveStages(
        _ stages: [String: StageConfig], to pluginDir: URL,
        fileManager: any FileSystemManager = FileManager.default
    ) throws {
        let encoder = JSONEncoder.piqleyPrettyPrint
        for (hookName, stageConfig) in stages {
            let stageFile = pluginDir
                .appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")

            if stageConfig.isEffectivelyEmpty {
                if fileManager.fileExists(atPath: stageFile.path) {
                    try fileManager.removeItem(at: stageFile)
                }
                continue
            }

            let data = try encoder.encode(stageConfig)
            try fileManager.write(data, to: stageFile, options: .atomic)
        }
    }

    /// Remove stage files on disk that are effectively empty, without writing anything.
    /// Call on exit even when no changes were made, to clean up stale empty files.
    static func cleanupEmptyStageFiles(
        stages: [String: StageConfig], pluginDir: URL,
        fileManager: any FileSystemManager = FileManager.default
    ) {
        for (hookName, stageConfig) in stages {
            guard stageConfig.isEffectivelyEmpty else { continue }
            let stageFile = pluginDir
                .appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")
            if fileManager.fileExists(atPath: stageFile.path) {
                try? fileManager.removeItem(at: stageFile)
            }
        }
    }
}
