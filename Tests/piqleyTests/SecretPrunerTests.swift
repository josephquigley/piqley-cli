import Foundation
import PiqleyCore
import Testing

@testable import piqley

/// In-memory secret store for pruner tests.
private final class PrunerMockSecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    func get(key: String) throws -> String {
        guard let value = secrets[key] else { throw SecretStoreError.notFound(key: key) }
        return value
    }

    func set(key: String, value: String) throws { secrets[key] = value }
    func delete(key: String) throws { secrets.removeValue(forKey: key) }
    func list() throws -> [String] { Array(secrets.keys) }
}

@Suite("SecretPruner")
struct SecretPrunerTests {
    @Test("Prunes orphaned secrets not referenced by any config or workflow")
    func prunesOrphanedSecrets() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let workflowDir = URL(fileURLWithPath: "/test/workflows")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workflowDir, withIntermediateDirectories: true)

        // Write a base config that references "prod-key"
        let configStore = BasePluginConfigStore(directory: configDir, fileManager: fm)
        let baseConfig = BasePluginConfig(secrets: ["API_KEY": "prod-key"])
        try configStore.save(baseConfig, for: "com.test.plugin")

        // Write a workflow that references "staging-key"
        let workflow = Workflow(
            name: "staging",
            displayName: "Staging",
            description: "",
            config: ["com.test.plugin": WorkflowPluginConfig(secrets: ["API_KEY": "staging-key"])]
        )
        let encoder = JSONEncoder.piqley
        let workflowData = try encoder.encode(workflow)
        try fm.write(workflowData, to: workflowDir.appendingPathComponent("staging.json"))

        // Secret store has referenced + orphaned secrets
        let secretStore = PrunerMockSecretStore()
        secretStore.secrets = [
            "prod-key": "secret1",
            "staging-key": "secret2",
            "orphaned-key": "secret3",
            "another-orphan": "secret4",
        ]

        let workflowScanner = WorkflowFileScanner(workflowsDirectory: workflowDir, fileManager: fm)
        let pruned = try SecretPruner.prune(
            configStore: configStore,
            workflowStore: workflowScanner,
            secretStore: secretStore,
            fileManager: fm
        )

        #expect(pruned.sorted() == ["another-orphan", "orphaned-key"])
        #expect(secretStore.secrets.count == 2)
        #expect(secretStore.secrets["prod-key"] == "secret1")
        #expect(secretStore.secrets["staging-key"] == "secret2")
    }

    @Test("No pruning when all secrets are referenced")
    func noPruningNeeded() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let workflowDir = URL(fileURLWithPath: "/test/workflows")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workflowDir, withIntermediateDirectories: true)

        let configStore = BasePluginConfigStore(directory: configDir, fileManager: fm)
        let baseConfig = BasePluginConfig(secrets: ["KEY": "my-alias"])
        try configStore.save(baseConfig, for: "com.test.plugin")

        let secretStore = PrunerMockSecretStore()
        secretStore.secrets = ["my-alias": "value"]

        let workflowScanner = WorkflowFileScanner(workflowsDirectory: workflowDir, fileManager: fm)
        let pruned = try SecretPruner.prune(
            configStore: configStore,
            workflowStore: workflowScanner,
            secretStore: secretStore,
            fileManager: fm
        )

        #expect(pruned.isEmpty)
        #expect(secretStore.secrets.count == 1)
    }

    @Test("Prunes all secrets when no configs or workflows exist")
    func prunesAllWhenNoConfigs() throws {
        let fm = InMemoryFileManager()
        let configDir = URL(fileURLWithPath: "/test/config")
        let workflowDir = URL(fileURLWithPath: "/test/workflows")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workflowDir, withIntermediateDirectories: true)

        let configStore = BasePluginConfigStore(directory: configDir, fileManager: fm)
        let secretStore = PrunerMockSecretStore()
        secretStore.secrets = ["orphan1": "v1", "orphan2": "v2"]

        let workflowScanner = WorkflowFileScanner(workflowsDirectory: workflowDir, fileManager: fm)
        let pruned = try SecretPruner.prune(
            configStore: configStore,
            workflowStore: workflowScanner,
            secretStore: secretStore,
            fileManager: fm
        )

        #expect(pruned.sorted() == ["orphan1", "orphan2"])
        #expect(secretStore.secrets.isEmpty)
    }
}
