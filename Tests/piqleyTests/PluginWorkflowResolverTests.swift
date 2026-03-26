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
            identifier: id, name: id, pluginSchemaVersion: "1"
        )
        let data = try JSONEncoder.piqleyPrettyPrint.encode(manifest)
        try data.write(to: dir.appendingPathComponent(PluginFile.manifest))
    }

    @Test("two args returns workflow and plugin directly")
    func twoArgs() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: "my-workflow", secondArg: "my-plugin",
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID) = try resolver.resolve()
        #expect(workflowName == "my-workflow")
        #expect(pluginID == "my-plugin")
    }

    @Test("single arg that is a plugin with one workflow auto-resolves")
    func singleArgPlugin() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.test.plugin"]])
        try createPlugin(id: "com.test.plugin")

        let resolver = PluginWorkflowResolver(
            firstArg: "com.test.plugin", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID) = try resolver.resolve()
        #expect(workflowName == "wf1")
        #expect(pluginID == "com.test.plugin")
    }

    @Test("single arg that is a workflow with one plugin auto-resolves")
    func singleArgWorkflow() throws {
        try createWorkflow(name: "wf1", plugins: ["pre-process": ["com.test.plugin"]])

        let resolver = PluginWorkflowResolver(
            firstArg: "wf1", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        let (workflowName, pluginID) = try resolver.resolve()
        #expect(workflowName == "wf1")
        #expect(pluginID == "com.test.plugin")
    }

    @Test("single arg that is neither workflow nor plugin throws")
    func singleArgUnknown() throws {
        let resolver = PluginWorkflowResolver(
            firstArg: "nonexistent", secondArg: nil,
            usageHint: "piqley plugin command", workflowsRoot: testDir,
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
            usageHint: "piqley plugin command", workflowsRoot: testDir,
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
            usageHint: "piqley plugin command", workflowsRoot: testDir,
            pluginsDirectory: pluginsDir
        )
        #expect(throws: CleanError.self) {
            try resolver.resolve()
        }
    }
}
