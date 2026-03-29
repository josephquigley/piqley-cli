import Foundation
import PiqleyCore
import Testing
@testable import piqley

@Suite("PluginWorkflowResolver")
struct PluginWorkflowResolverTests {
    let testDir: URL
    let pluginsDir: URL

    init() throws {
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-resolver-\(UUID().uuidString)")
        pluginsDir = testDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    }

    private func createWorkflow(name: String, plugins: [String: [String]]) throws {
        var wf = Workflow(name: name, displayName: name, description: "")
        wf.pipeline = plugins
        try WorkflowStore.save(wf, root: testDir)
    }

    private func createPlugin(id: String) throws {
        let dir = pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            identifier: id, name: id, type: .static, pluginSchemaVersion: "1"
        )
        let data = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
        try data.write(to: dir.appendingPathComponent(PluginFile.manifest))
    }

    private func loadedPlugin(id: String) -> LoadedPlugin {
        LoadedPlugin(
            identifier: id,
            name: id,
            directory: pluginsDir.appendingPathComponent(id),
            manifest: PluginManifest(identifier: id, name: id, type: .static, pluginSchemaVersion: "1"),
            stages: [:]
        )
    }

    @Test("two args returns workflow and plugin directly")
    func twoArgs() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: "my-workflow", secondArg: "my-plugin",
            usageHint: "piqley workflow command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID, _) = try resolver.resolve()
        #expect(workflowName == "my-workflow")
        #expect(pluginID == "my-plugin")
    }

    @Test("single arg that is a plugin with one workflow auto-resolves")
    func singleArgPlugin() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.test.plugin"]])
        try createPlugin(id: "com.test.plugin")

        let resolver = PluginWorkflowResolver(
            firstArg: "com.test.plugin", secondArg: nil,
            usageHint: "piqley workflow command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID, _) = try resolver.resolve()
        #expect(workflowName == "wf1")
        #expect(pluginID == "com.test.plugin")
    }

    @Test("single arg that is a workflow with one plugin auto-resolves")
    func singleArgWorkflow() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.test.plugin"]])

        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: nil,
            usageHint: "piqley workflow command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID, _) = try resolver.resolve()
        #expect(workflowName == "wf1")
        #expect(pluginID == "com.test.plugin")
    }

    @Test("single arg that is neither workflow nor plugin throws")
    func singleArgUnknown() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: "nonexistent", secondArg: nil,
            usageHint: "piqley workflow command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }

    @Test("single arg plugin not in any workflow throws")
    func pluginNotInWorkflow() throws {
        try createPlugin(id: "com.orphan.plugin")

        let resolver = PluginWorkflowResolver(
            firstArg: "com.orphan.plugin", secondArg: nil,
            usageHint: "piqley workflow command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }

    @Test("single arg workflow with no plugins throws")
    func workflowNoPlugins() throws {
        try createWorkflow(name: "empty-wf", plugins: [:])

        let resolver = PluginWorkflowResolver(
            firstArg: "empty-wf", secondArg: nil,
            usageHint: "piqley workflow command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }

    // MARK: - Inactive Plugin Tests

    @Test("two args with discovered plugins returns isInactive true when not in pipeline")
    func twoArgsInactive() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])
        try createPlugin(id: "com.inactive.plugin")

        let discovered = [loadedPlugin(id: "com.inactive.plugin")]
        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: "com.inactive.plugin",
            usageHint: "piqley workflow rules", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir, discoveredPlugins: discovered
        )
        let result = try resolver.resolve()
        #expect(result.workflowName == "wf1")
        #expect(result.pluginID == "com.inactive.plugin")
        #expect(result.isInactive == true)
    }

    @Test("two args with discovered plugins returns isInactive false when in pipeline")
    func twoArgsActive() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])
        try createPlugin(id: "com.active.plugin")

        let discovered = [loadedPlugin(id: "com.active.plugin")]
        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: "com.active.plugin",
            usageHint: "piqley workflow rules", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir, discoveredPlugins: discovered
        )
        let result = try resolver.resolve()
        #expect(result.workflowName == "wf1")
        #expect(result.pluginID == "com.active.plugin")
        #expect(result.isInactive == false)
    }

    @Test("two args without discovered plugins returns isInactive false (legacy behavior)")
    func twoArgsLegacy() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])

        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: "com.active.plugin",
            usageHint: "piqley workflow rules", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let result = try resolver.resolve()
        #expect(result.workflowName == "wf1")
        #expect(result.pluginID == "com.active.plugin")
        #expect(result.isInactive == false)
    }

    @Test("single arg workflow with one plugin auto-resolves with isInactive false")
    func singleArgWorkflowWithDiscovered() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.active.plugin"]])

        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: nil,
            usageHint: "piqley workflow rules", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir, discoveredPlugins: []
        )
        let result = try resolver.resolve()
        #expect(result.workflowName == "wf1")
        #expect(result.pluginID == "com.active.plugin")
        #expect(result.isInactive == false)
    }
}
