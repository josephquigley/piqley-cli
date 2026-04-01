import Foundation
import PiqleyCore

enum WorkflowStore {
    static var workflowsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.workflows)
    }

    static func ensureDirectory(root: URL? = nil) throws {
        let dir = root ?? workflowsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func directoryURL(name: String, root: URL? = nil) -> URL {
        (root ?? workflowsDirectory).appendingPathComponent(name)
    }

    static func fileURL(name: String, root: URL? = nil) -> URL {
        directoryURL(name: name, root: root).appendingPathComponent("workflow.json")
    }

    static func rulesDirectory(name: String, root: URL? = nil) -> URL {
        directoryURL(name: name, root: root).appendingPathComponent("rules")
    }

    static func pluginRulesDirectory(workflowName: String, pluginIdentifier: String, root: URL? = nil) -> URL {
        rulesDirectory(name: workflowName, root: root).appendingPathComponent(pluginIdentifier)
    }

    /// Scans all plugin rules directories under a workflow for stage files
    /// and auto-registers any stage names not already known to the registry.
    static func scanAndRegisterStages(
        workflowName: String, registry: inout StageRegistry, root: URL? = nil
    ) {
        let rulesDir = rulesDirectory(name: workflowName, root: root)
        guard let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        let knownNames = registry.allKnownNames
        for pluginDir in pluginDirs {
            guard (try? pluginDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: pluginDir, includingPropertiesForKeys: nil
            ) else { continue }

            for file in files {
                let filename = file.lastPathComponent
                guard filename.hasPrefix(PluginFile.stagePrefix),
                      filename.hasSuffix(PluginFile.stageSuffix) else { continue }
                let stageName = String(
                    filename.dropFirst(PluginFile.stagePrefix.count)
                        .dropLast(PluginFile.stageSuffix.count)
                )
                if !knownNames.contains(stageName) {
                    registry.autoRegister(stageName)
                }
            }
        }
    }

    /// Checks whether a specific stage file exists in a workflow's rules directory for a plugin.
    static func hasStageFile(
        workflowName: String, pluginIdentifier: String, stageName: String, root: URL? = nil
    ) -> Bool {
        let stageFile = pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
        ).appendingPathComponent("\(PluginFile.stagePrefix)\(stageName)\(PluginFile.stageSuffix)")
        return FileManager.default.fileExists(atPath: stageFile.path)
    }

    static func exists(name: String, root: URL? = nil) -> Bool {
        let dir = directoryURL(name: name, root: root)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func list(root: URL? = nil) throws -> [String] {
        let dir = root ?? workflowsDirectory
        try ensureDirectory(root: root)
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("workflow.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    static func load(name: String, root: URL? = nil) throws -> Workflow {
        let data = try Data(contentsOf: fileURL(name: name, root: root))
        return try JSONDecoder.piqley.decode(Workflow.self, from: data)
    }

    static func loadAll(root: URL? = nil) throws -> [Workflow] {
        try list(root: root).map { try load(name: $0, root: root) }
    }

    static func save(_ workflow: Workflow, root: URL? = nil) throws {
        let dir = directoryURL(name: workflow.name, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleaned = workflow.strippingLifecycleStages()
        let data = try JSONEncoder.piqleyPrettyPrint.encode(cleaned)
        try data.write(to: fileURL(name: workflow.name, root: root))
    }

    static func delete(name: String, root: URL? = nil) throws {
        let dir = directoryURL(name: name, root: root)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw WorkflowError.notFound(name)
        }
        try FileManager.default.removeItem(at: dir)
    }

    static func clone(source: String, destination: String, root: URL? = nil) throws {
        guard exists(name: source, root: root) else {
            throw WorkflowError.notFound(source)
        }
        guard !exists(name: destination, root: root) else {
            throw WorkflowError.alreadyExists(destination)
        }
        // Deep-copy the entire directory (includes rules/)
        let srcDir = directoryURL(name: source, root: root)
        let dstDir = directoryURL(name: destination, root: root)
        try FileManager.default.copyItem(at: srcDir, to: dstDir)

        // Update the workflow.json with new name
        var workflow = try load(name: destination, root: root)
        workflow.name = destination
        workflow.displayName = destination
        try save(workflow, root: root)
    }

    // MARK: - Rule Seeding

    /// Copy plugin's built-in stage files into the workflow's rules directory.
    /// Skips if the plugin already has a rules directory in this workflow (preserves customizations).
    static func seedRules(
        workflowName: String,
        pluginIdentifier: String,
        pluginDirectory: URL,
        root: URL? = nil
    ) throws {
        let destDir = pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
        )

        // Skip if already seeded (preserves customizations)
        if FileManager.default.fileExists(atPath: destDir.path) { return }

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Copy all stage-*.json files from plugin directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginDirectory, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard name.hasPrefix(PluginFile.stagePrefix),
                  name.hasSuffix(PluginFile.stageSuffix) else { continue }
            try FileManager.default.copyItem(
                at: file, to: destDir.appendingPathComponent(name)
            )
        }
    }

    /// Remove all rules for a plugin from a workflow.
    static func removePluginRules(
        workflowName: String,
        pluginIdentifier: String,
        root: URL? = nil
    ) throws {
        let dir = pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
        )
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Seed the default workflow if no workflows exist.
    static func seedDefault(activeStages: [String], root: URL? = nil) throws {
        try ensureDirectory(root: root)
        let existing = try list(root: root)
        if existing.isEmpty {
            try save(
                .empty(name: "default", displayName: "Default", description: "Default workflow", activeStages: activeStages),
                root: root
            )
        }
    }
}

enum WorkflowError: Error, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)

    var description: String {
        switch self {
        case let .notFound(name): "Workflow '\(name)' not found"
        case let .alreadyExists(name): "Workflow '\(name)' already exists"
        }
    }
}
