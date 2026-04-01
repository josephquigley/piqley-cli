import Foundation
import PiqleyCore

enum WorkflowStore {
    static var workflowsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.workflows)
    }

    static func ensureDirectory(root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws {
        let dir = root ?? workflowsDirectory
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
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
        workflowName: String, registry: inout StageRegistry, root: URL? = nil,
        fileManager: any FileSystemManager = FileManager.default
    ) {
        let rulesDir = rulesDirectory(name: workflowName, root: root)
        guard let pluginDirs = try? fileManager.contentsOfDirectory(
            at: rulesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        let knownNames = registry.allKnownNames
        for pluginDir in pluginDirs {
            guard (try? pluginDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
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
        workflowName: String, pluginIdentifier: String, stageName: String, root: URL? = nil,
        fileManager: any FileSystemManager = FileManager.default
    ) -> Bool {
        let stageFile = pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
        ).appendingPathComponent("\(PluginFile.stagePrefix)\(stageName)\(PluginFile.stageSuffix)")
        return fileManager.fileExists(atPath: stageFile.path)
    }

    static func exists(name: String, root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) -> Bool {
        let dir = directoryURL(name: name, root: root)
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func list(root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws -> [String] {
        let dir = root ?? workflowsDirectory
        try ensureDirectory(root: root, fileManager: fileManager)
        let contents = try fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("workflow.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    static func load(name: String, root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws -> Workflow {
        let data = try fileManager.contents(of: fileURL(name: name, root: root))
        return try JSONDecoder.piqley.decode(Workflow.self, from: data)
    }

    static func loadAll(root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws -> [Workflow] {
        try list(root: root, fileManager: fileManager).map { try load(name: $0, root: root, fileManager: fileManager) }
    }

    static func save(_ workflow: Workflow, root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws {
        let dir = directoryURL(name: workflow.name, root: root)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleaned = workflow.strippingLifecycleStages()
        let data = try JSONEncoder.piqleyPrettyPrint.encode(cleaned)
        try fileManager.write(data, to: fileURL(name: workflow.name, root: root))
    }

    static func delete(name: String, root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws {
        let dir = directoryURL(name: name, root: root)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw WorkflowError.notFound(name)
        }
        try fileManager.removeItem(at: dir)
    }

    static func clone(source: String, destination: String, root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws {
        guard exists(name: source, root: root, fileManager: fileManager) else {
            throw WorkflowError.notFound(source)
        }
        guard !exists(name: destination, root: root, fileManager: fileManager) else {
            throw WorkflowError.alreadyExists(destination)
        }
        // Deep-copy the entire directory (includes rules/)
        let srcDir = directoryURL(name: source, root: root)
        let dstDir = directoryURL(name: destination, root: root)
        try fileManager.copyItem(at: srcDir, to: dstDir)

        // Update the workflow.json with new name
        var workflow = try load(name: destination, root: root, fileManager: fileManager)
        workflow.name = destination
        workflow.displayName = destination
        try save(workflow, root: root, fileManager: fileManager)
    }

    // MARK: - Rule Seeding

    /// Copy plugin's built-in stage files into the workflow's rules directory.
    /// Skips if the plugin already has a rules directory in this workflow (preserves customizations).
    static func seedRules(
        workflowName: String,
        pluginIdentifier: String,
        pluginDirectory: URL,
        root: URL? = nil,
        fileManager: any FileSystemManager = FileManager.default
    ) throws {
        let destDir = pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
        )

        // Skip if already seeded (preserves customizations)
        if fileManager.fileExists(atPath: destDir.path) { return }

        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Copy all stage-*.json files from plugin directory
        let contents = try fileManager.contentsOfDirectory(
            at: pluginDirectory, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard name.hasPrefix(PluginFile.stagePrefix),
                  name.hasSuffix(PluginFile.stageSuffix) else { continue }
            try fileManager.copyItem(
                at: file, to: destDir.appendingPathComponent(name)
            )
        }
    }

    /// Remove all rules for a plugin from a workflow.
    static func removePluginRules(
        workflowName: String,
        pluginIdentifier: String,
        root: URL? = nil,
        fileManager: any FileSystemManager = FileManager.default
    ) throws {
        let dir = pluginRulesDirectory(
            workflowName: workflowName, pluginIdentifier: pluginIdentifier, root: root
        )
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    /// Seed the default workflow if no workflows exist.
    static func seedDefault(activeStages: [String], root: URL? = nil, fileManager: any FileSystemManager = FileManager.default) throws {
        try ensureDirectory(root: root, fileManager: fileManager)
        let existing = try list(root: root, fileManager: fileManager)
        if existing.isEmpty {
            try save(
                .empty(name: "default", displayName: "Default", description: "Default workflow", activeStages: activeStages),
                root: root,
                fileManager: fileManager
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
