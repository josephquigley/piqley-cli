import Foundation
import PiqleyCore

/// Checks for stage drift between an updated plugin and the workflows that reference it.
/// Called during `plugin update` to detect new or removed non-lifecycle stages.
enum StageDriftChecker {
    /// Extracts non-lifecycle stage names from stage files in a plugin directory.
    static func extractStageNames(
        from directory: URL,
        fileManager: any FileSystemManager = FileManager.default
    ) -> Set<String> {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        var names = Set<String>()
        for file in files {
            let filename = file.lastPathComponent
            guard filename.hasPrefix(PluginFile.stagePrefix),
                  filename.hasSuffix(PluginFile.stageSuffix) else { continue }
            let stageName = String(
                filename.dropFirst(PluginFile.stagePrefix.count)
                    .dropLast(PluginFile.stageSuffix.count)
            )
            guard !StandardHook.requiredStageNames.contains(stageName) else { continue }
            names.insert(stageName)
        }
        return names
    }

    /// Snapshot old stage names before the update replaces the plugin directory.
    /// Peeks at the zip's manifest to derive the plugin identifier.
    static func snapshotOldStageNames(
        pluginsDir: URL,
        zipURL: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("piqley-stage-peek-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempDir) }

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zipURL.path, tempDir.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { return [] }

            let contents = try fileManager.contentsOfDirectory(
                at: tempDir, includingPropertiesForKeys: [.isDirectoryKey]
            )
            guard let pluginDir = contents.first(where: {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) else { return [] }

            let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder.piqley.decode(PluginManifest.self, from: data)

            let installedDir = pluginsDir.appendingPathComponent(manifest.identifier)
            guard fileManager.fileExists(atPath: installedDir.path) else { return [] }
            return extractStageNames(from: installedDir, fileManager: fileManager)
        } catch {
            return []
        }
    }

    /// Compare old and new stages, then prompt for new stages and warn about removed ones.
    static func check(
        identifier: String,
        pluginsDir: URL,
        oldStageNames: Set<String>,
        fileManager: FileManager = .default
    ) throws {
        let installedDir = pluginsDir.appendingPathComponent(identifier)
        let newStageNames = extractStageNames(from: installedDir, fileManager: fileManager)

        let addedStages = newStageNames.subtracting(oldStageNames)
        let removedStages = oldStageNames.subtracting(newStageNames)

        guard !addedStages.isEmpty || !removedStages.isEmpty else { return }

        let workflows: [Workflow]
        do {
            workflows = try WorkflowStore.loadAll()
        } catch {
            return
        }

        let affectedWorkflows = workflows.filter { workflow in
            workflow.pipeline.values.contains { $0.contains(identifier) }
        }
        guard !affectedWorkflows.isEmpty else { return }

        for workflow in affectedWorkflows {
            for stage in removedStages.sorted() {
                let inPipeline = workflow.pipeline[stage]?.contains(identifier) == true
                let hasRulesFile = WorkflowStore.hasStageFile(
                    workflowName: workflow.name,
                    pluginIdentifier: identifier,
                    stageName: stage
                )
                if inPipeline || hasRulesFile {
                    print(
                        "Warning: Stage '\(stage)' was removed from plugin "
                            + "but workflow '\(workflow.name)' still references it."
                    )
                }
            }

            for stage in addedStages.sorted() {
                let alreadyInPipeline = workflow.pipeline[stage]?.contains(identifier) == true
                if alreadyInPipeline { continue }

                print("Plugin now supports stage '\(stage)'.")
                print("Add to workflow '\(workflow.name)'? [Y/n] ", terminator: "")
                let response = (readLine() ?? "y").trimmingCharacters(in: .whitespaces).lowercased()
                guard response.isEmpty || response == "y" || response == "yes" else { continue }

                let sourceFile = installedDir
                    .appendingPathComponent("\(PluginFile.stagePrefix)\(stage)\(PluginFile.stageSuffix)")
                let destDir = WorkflowStore.pluginRulesDirectory(
                    workflowName: workflow.name, pluginIdentifier: identifier
                )
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                let destFile = destDir
                    .appendingPathComponent("\(PluginFile.stagePrefix)\(stage)\(PluginFile.stageSuffix)")
                if !fileManager.fileExists(atPath: destFile.path) {
                    try fileManager.copyItem(at: sourceFile, to: destFile)
                }

                var updated = workflow
                if updated.pipeline[stage] == nil {
                    updated.pipeline[stage] = []
                }
                updated.pipeline[stage]?.append(identifier)
                try WorkflowStore.save(updated)

                print("Added '\(identifier)' to stage '\(stage)' in workflow '\(workflow.name)'.")
            }
        }
    }
}
