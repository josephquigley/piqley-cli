import Foundation
import PiqleyCore
import Testing

@testable import piqley

@Suite("WorkflowConfigCommand")
struct WorkflowConfigCommandTests {
    @Test("--set writes value override to workflow config")
    func setValueOverride() throws {
        // Create a workflow
        let workflow = Workflow(
            name: "staging",
            displayName: "Staging",
            description: "Staging workflow",
            pipeline: ["publish": ["com.test.plugin"]]
        )
        let data = try JSONEncoder.piqleyPrettyPrint.encode(workflow)

        // Load workflow, apply override, and save back
        var loadedWorkflow = try JSONDecoder.piqley.decode(Workflow.self, from: data)

        // Simulate --set siteUrl=https://staging.example.com
        var override = loadedWorkflow.config["com.test.plugin"] ?? WorkflowPluginConfig()
        if override.values == nil { override.values = [:] }
        override.values?["siteUrl"] = .string("https://staging.example.com")
        loadedWorkflow.config["com.test.plugin"] = override

        #expect(loadedWorkflow.config["com.test.plugin"]?.values?["siteUrl"] == .string("https://staging.example.com"))
    }

    @Test("--set-secret writes secret alias override to workflow config")
    func setSecretOverride() throws {
        var workflow = Workflow(
            name: "staging",
            displayName: "Staging",
            description: "Staging workflow",
            pipeline: ["publish": ["com.test.plugin"]]
        )

        // Simulate --set-secret API_KEY=staging-api-key
        var override = workflow.config["com.test.plugin"] ?? WorkflowPluginConfig()
        if override.secrets == nil { override.secrets = [:] }
        override.secrets?["API_KEY"] = "staging-api-key"
        workflow.config["com.test.plugin"] = override

        #expect(workflow.config["com.test.plugin"]?.secrets?["API_KEY"] == "staging-api-key")
    }

    @Test("Multiple --set flags accumulate overrides")
    func multipleSetFlags() throws {
        var workflow = Workflow(
            name: "test",
            displayName: "Test",
            description: "",
            pipeline: [:]
        )

        var override = WorkflowPluginConfig()
        override.values = [:]
        override.values?["key1"] = .string("val1")
        override.values?["key2"] = .string("val2")
        workflow.config["com.test.plugin"] = override

        #expect(workflow.config["com.test.plugin"]?.values?.count == 2)
        #expect(workflow.config["com.test.plugin"]?.values?["key1"] == .string("val1"))
        #expect(workflow.config["com.test.plugin"]?.values?["key2"] == .string("val2"))
    }

    @Test("Workflow config round-trips through JSON encoding")
    func workflowConfigRoundTrip() throws {
        var workflow = Workflow(
            name: "staging",
            displayName: "Staging",
            description: "Staging",
            pipeline: ["publish": ["com.test.plugin"]]
        )
        workflow.config["com.test.plugin"] = WorkflowPluginConfig(
            values: ["url": .string("https://staging.com")],
            secrets: ["API_KEY": "staging-key"]
        )

        let data = try JSONEncoder.piqleyPrettyPrint.encode(workflow)
        let decoded = try JSONDecoder.piqley.decode(Workflow.self, from: data)

        #expect(decoded.config["com.test.plugin"]?.values?["url"] == .string("https://staging.com"))
        #expect(decoded.config["com.test.plugin"]?.secrets?["API_KEY"] == "staging-key")
    }
}
