import Foundation
import PiqleyCore

enum StageFileManager {
    /// Save stage configs to disk. Effectively empty stages are not written;
    /// existing empty stage files are removed.
    static func saveStages(_ stages: [String: StageConfig], to pluginDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (hookName, stageConfig) in stages {
            let stageFile = pluginDir
                .appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")

            if stageConfig.isEffectivelyEmpty {
                if FileManager.default.fileExists(atPath: stageFile.path) {
                    try FileManager.default.removeItem(at: stageFile)
                }
                continue
            }

            let data = try encoder.encode(stageConfig)
            try data.write(to: stageFile, options: .atomic)
        }
    }

    /// Remove stage files on disk that are effectively empty, without writing anything.
    /// Call on exit even when no changes were made, to clean up stale empty files.
    static func cleanupEmptyStageFiles(stages: [String: StageConfig], pluginDir: URL) {
        for (hookName, stageConfig) in stages {
            guard stageConfig.isEffectivelyEmpty else { continue }
            let stageFile = pluginDir
                .appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")
            if FileManager.default.fileExists(atPath: stageFile.path) {
                try? FileManager.default.removeItem(at: stageFile)
            }
        }
    }
}
