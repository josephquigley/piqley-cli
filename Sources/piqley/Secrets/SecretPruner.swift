import Foundation
import PiqleyCore

/// Identifies and removes orphaned secrets that are no longer referenced
/// by any base config file or workflow file.
enum SecretPruner {
    /// Scans all base config files and workflow files for referenced secret aliases,
    /// then deletes any secrets in the store that are not referenced.
    /// Returns the list of pruned alias names.
    @discardableResult
    static func prune(
        configStore: BasePluginConfigStore,
        workflowStore: WorkflowFileScanner = .default,
        secretStore: any SecretStore,
        fileManager: any FileSystemManager = FileManager.default
    ) throws -> [String] {
        let referencedAliases = try collectReferencedAliases(
            configStore: configStore,
            workflowStore: workflowStore,
            fileManager: fileManager
        )
        let allSecrets = try Set(secretStore.list())
        let orphaned = allSecrets.subtracting(referencedAliases)

        var pruned: [String] = []
        for alias in orphaned.sorted() {
            try secretStore.delete(key: alias)
            pruned.append(alias)
        }
        return pruned
    }

    /// Collects all secret aliases referenced across base configs and workflows.
    static func collectReferencedAliases(
        configStore: BasePluginConfigStore,
        workflowStore: WorkflowFileScanner = .default,
        fileManager: any FileSystemManager = FileManager.default
    ) throws -> Set<String> {
        var referenced = Set<String>()

        // Scan base config files
        let configFiles = try listFiles(in: configStore.directory, extension: "json", fileManager: fileManager)
        for file in configFiles {
            let data = try fileManager.contents(of: file)
            if let config = try? JSONDecoder.piqley.decode(BasePluginConfig.self, from: data) {
                for alias in config.secrets.values {
                    referenced.insert(alias)
                }
            }
        }

        // Scan workflow files
        let workflowFiles = try workflowStore.listWorkflowFiles()
        for file in workflowFiles {
            let data = try fileManager.contents(of: file)
            if let workflow = try? JSONDecoder.piqley.decode(Workflow.self, from: data) {
                for pluginConfig in workflow.config.values {
                    if let secrets = pluginConfig.secrets {
                        for alias in secrets.values {
                            referenced.insert(alias)
                        }
                    }
                }
            }
        }

        return referenced
    }

    private static func listFiles(
        in directory: URL, extension ext: String,
        fileManager: any FileSystemManager = FileManager.default
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == ext }
    }
}

/// Abstraction for scanning workflow files to allow testing without real filesystem.
struct WorkflowFileScanner: Sendable {
    let workflowsDirectory: URL
    let fileManager: any FileSystemManager

    static var `default`: WorkflowFileScanner {
        WorkflowFileScanner(
            workflowsDirectory: WorkflowStore.workflowsDirectory,
            fileManager: FileManager.default
        )
    }

    func listWorkflowFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: workflowsDirectory.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: workflowsDirectory, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "json" }
    }
}
