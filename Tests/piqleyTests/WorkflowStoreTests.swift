import Foundation
import PiqleyCore
import Testing
@testable import piqley

@Suite("WorkflowStore")
struct WorkflowStoreTests {
    let testDir: URL

    init() throws {
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-wf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    @Test("directoryURL returns workflow-name subdirectory")
    func directoryURL() {
        let url = WorkflowStore.directoryURL(name: "default", root: testDir)
        #expect(url.lastPathComponent == "default")
    }

    @Test("fileURL returns workflow.json inside directory")
    func fileURL() {
        let url = WorkflowStore.fileURL(name: "default", root: testDir)
        #expect(url.lastPathComponent == "workflow.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "default")
    }

    @Test("rulesDirectory returns rules/ inside workflow directory")
    func rulesDirectory() {
        let url = WorkflowStore.rulesDirectory(name: "default", root: testDir)
        #expect(url.lastPathComponent == "rules")
        #expect(url.deletingLastPathComponent().lastPathComponent == "default")
    }

    @Test("save creates directory and workflow.json")
    func saveCreatesDirectory() throws {
        let workflow = Workflow(name: "test", displayName: "Test", description: "A test workflow")
        try WorkflowStore.save(workflow, root: testDir)

        let dirExists = FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("test").path
        )
        #expect(dirExists)

        let fileExists = FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("test/workflow.json").path
        )
        #expect(fileExists)
    }

    @Test("load reads from directory layout")
    func loadFromDirectory() throws {
        let workflow = Workflow(name: "roundtrip", displayName: "RT", description: "desc")
        try WorkflowStore.save(workflow, root: testDir)

        let loaded = try WorkflowStore.load(name: "roundtrip", root: testDir)
        #expect(loaded.name == "roundtrip")
        #expect(loaded.displayName == "RT")
    }

    @Test("list returns workflow directory names")
    func listWorkflows() throws {
        try WorkflowStore.save(
            Workflow(name: "alpha", displayName: "Alpha", description: ""),
            root: testDir
        )
        try WorkflowStore.save(
            Workflow(name: "beta", displayName: "Beta", description: ""),
            root: testDir
        )
        let names = try WorkflowStore.list(root: testDir)
        #expect(names == ["alpha", "beta"])
    }

    @Test("delete removes entire workflow directory")
    func deleteWorkflow() throws {
        try WorkflowStore.save(
            Workflow(name: "doomed", displayName: "Doomed", description: ""),
            root: testDir
        )
        try WorkflowStore.delete(name: "doomed", root: testDir)
        let exists = FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("doomed").path
        )
        #expect(!exists)
    }

    @Test("clone deep-copies directory including rules")
    func cloneDeepCopies() throws {
        try WorkflowStore.save(
            Workflow(name: "src", displayName: "Source", description: ""),
            root: testDir
        )
        // Create a rules file in source
        let rulesDir = testDir.appendingPathComponent("src/rules/my.plugin")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: rulesDir.appendingPathComponent("stage-publish.json"))

        try WorkflowStore.clone(source: "src", destination: "dst", root: testDir)

        // Verify workflow.json exists with new name
        let loaded = try WorkflowStore.load(name: "dst", root: testDir)
        #expect(loaded.name == "dst")

        // Verify rules were deep-copied
        let copiedRule = testDir.appendingPathComponent("dst/rules/my.plugin/stage-publish.json")
        #expect(FileManager.default.fileExists(atPath: copiedRule.path))
    }

    @Test("exists checks for workflow directory")
    func existsCheck() throws {
        #expect(!WorkflowStore.exists(name: "nope", root: testDir))
        try WorkflowStore.save(
            Workflow(name: "yep", displayName: "Yep", description: ""),
            root: testDir
        )
        #expect(WorkflowStore.exists(name: "yep", root: testDir))
    }

    @Test("seedDefault creates default workflow when none exist")
    func seedDefault() throws {
        try WorkflowStore.seedDefault(activeStages: ["pre-process", "publish"], root: testDir)
        let names = try WorkflowStore.list(root: testDir)
        #expect(names == ["default"])
        let wf = try WorkflowStore.load(name: "default", root: testDir)
        #expect(wf.pipeline.keys.sorted() == ["pre-process", "publish"])
    }

    @Test("seedDefault does not overwrite existing workflows")
    func seedDefaultNoOverwrite() throws {
        try WorkflowStore.save(
            Workflow(name: "custom", displayName: "Custom", description: ""),
            root: testDir
        )
        try WorkflowStore.seedDefault(activeStages: ["publish"], root: testDir)
        let names = try WorkflowStore.list(root: testDir)
        #expect(names == ["custom"]) // No "default" added
    }

    // MARK: - Rule Seeding

    @Test("seedRules copies plugin stage files into workflow rules dir")
    func seedRulesCopiesStageFiles() throws {
        // Create a workflow
        try WorkflowStore.save(
            Workflow(name: "test", displayName: "Test", description: ""),
            root: testDir
        )

        // Create a fake plugin dir with stage files
        let pluginDir = testDir.appendingPathComponent("plugins/my.plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let stageData = Data("""
        {"preRules": [{"match": {"field": "original:IPTC:Keywords", "pattern": "test"}, "emit": [], "write": []}]}
        """.utf8)
        try stageData.write(to: pluginDir.appendingPathComponent("stage-publish.json"))
        try stageData.write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))

        // Seed rules
        try WorkflowStore.seedRules(
            workflowName: "test",
            pluginIdentifier: "my.plugin",
            pluginDirectory: pluginDir,
            root: testDir
        )

        // Verify files were copied
        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
        )
        let publishExists = FileManager.default.fileExists(
            atPath: rulesDir.appendingPathComponent("stage-publish.json").path
        )
        let preProcessExists = FileManager.default.fileExists(
            atPath: rulesDir.appendingPathComponent("stage-pre-process.json").path
        )
        #expect(publishExists)
        #expect(preProcessExists)
    }

    @Test("seedRules skips if rules directory already exists")
    func seedRulesSkipsExisting() throws {
        try WorkflowStore.save(
            Workflow(name: "test", displayName: "Test", description: ""),
            root: testDir
        )

        // Create plugin dir
        let pluginDir = testDir.appendingPathComponent("plugins/my.plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pluginDir.appendingPathComponent("stage-publish.json"))

        // Pre-create rules dir with custom content
        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
        )
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let customData = Data("{\"custom\": true}".utf8)
        try customData.write(to: rulesDir.appendingPathComponent("stage-publish.json"))

        // Seed rules (should skip)
        try WorkflowStore.seedRules(
            workflowName: "test",
            pluginIdentifier: "my.plugin",
            pluginDirectory: pluginDir,
            root: testDir
        )

        // Verify custom content was preserved
        let data = try Data(contentsOf: rulesDir.appendingPathComponent("stage-publish.json"))
        let str = String(data: data, encoding: .utf8)
        #expect(str?.contains("custom") == true)
    }

    @Test("removePluginRules deletes the plugin rules directory")
    func removePluginRules() throws {
        try WorkflowStore.save(
            Workflow(name: "test", displayName: "Test", description: ""),
            root: testDir
        )
        let rulesDir = WorkflowStore.pluginRulesDirectory(
            workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
        )
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: rulesDir.appendingPathComponent("stage-publish.json"))

        try WorkflowStore.removePluginRules(
            workflowName: "test", pluginIdentifier: "my.plugin", root: testDir
        )

        #expect(!FileManager.default.fileExists(atPath: rulesDir.path))
    }
}
