import Foundation

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
        secretStore: any SecretStore
    ) throws -> [String] {
        let referencedAliases = try collectReferencedAliases(
            configStore: configStore,
            workflowStore: workflowStore
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
        workflowStore: WorkflowFileScanner = .default
    ) throws -> Set<String> {
        var referenced = Set<String>()

        // Scan base config files
        let configFiles = try listFiles(in: configStore.directory, extension: "json")
        for file in configFiles {
            let data = try Data(contentsOf: file)
            if let config = try? JSONDecoder().decode(BasePluginConfig.self, from: data) {
                for alias in config.secrets.values {
                    referenced.insert(alias)
                }
            }
        }

        // Scan workflow files
        let workflowFiles = try workflowStore.listWorkflowFiles()
        for file in workflowFiles {
            let data = try Data(contentsOf: file)
            if let workflow = try? JSONDecoder().decode(Workflow.self, from: data) {
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

    private static func listFiles(in directory: URL, extension ext: String) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == ext }
    }
}

/// Abstraction for scanning workflow files to allow testing without real filesystem.
struct WorkflowFileScanner: Sendable {
    let workflowsDirectory: URL

    static var `default`: WorkflowFileScanner {
        WorkflowFileScanner(workflowsDirectory: WorkflowStore.workflowsDirectory)
    }

    func listWorkflowFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workflowsDirectory.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            at: workflowsDirectory, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "json" }
    }
}
