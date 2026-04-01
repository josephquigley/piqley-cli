import Foundation
import PiqleyCore
import Testing
@testable import piqley

@Suite("Workflow")
struct ConfigTests {
    @Test("decodes workflow from JSON")
    func testDecodeWorkflow() throws {
        let json = """
        {
          "name": "test",
          "displayName": "Test",
          "description": "A test workflow",
          "schemaVersion": 1,
          "pipeline": {
            "pre-process": ["piqley-metadata", "piqley-resize"],
            "publish": ["ghost"]
          }
        }
        """
        let workflow = try JSONDecoder.piqley.decode(Workflow.self, from: Data(json.utf8))
        #expect(workflow.name == "test")
        #expect(workflow.pipeline["pre-process"] == ["piqley-metadata", "piqley-resize"])
        #expect(workflow.pipeline["publish"] == ["ghost"])
    }

    @Test("empty workflow has user-configurable hooks only")
    func testEmptyWorkflow() {
        let workflow = Workflow.empty(name: "default", activeStages: StandardHook.defaultStageNames)
        #expect(workflow.pipeline.count == 4)
        #expect(workflow.pipeline["pipeline-start"] == nil)
        #expect(workflow.pipeline["pre-process"] == [])
        #expect(workflow.pipeline["post-process"] == [])
        #expect(workflow.pipeline["publish"] == [])
        #expect(workflow.pipeline["post-publish"] == [])
        #expect(workflow.pipeline["pipeline-finished"] == nil)
    }

    @Test("strippingLifecycleStages removes pipeline-start and pipeline-finished")
    func testStrippingLifecycleStages() {
        let workflow = Workflow(
            name: "test", displayName: "test", description: "",
            pipeline: [
                "pipeline-start": ["com.test.plugin"],
                "pre-process": ["com.test.plugin"],
                "publish": ["com.test.plugin"],
                "pipeline-finished": ["com.test.plugin"]
            ]
        )
        let stripped = workflow.strippingLifecycleStages()
        #expect(stripped.pipeline["pipeline-start"] == nil)
        #expect(stripped.pipeline["pipeline-finished"] == nil)
        #expect(stripped.pipeline["pre-process"] == ["com.test.plugin"])
        #expect(stripped.pipeline["publish"] == ["com.test.plugin"])
    }

    @Test("encodes and decodes round-trip")
    func testRoundTrip() throws {
        var workflow = Workflow.empty(name: "test", displayName: "Test", activeStages: StandardHook.defaultStageNames)
        workflow.pipeline["publish"] = ["ghost"]
        let data = try JSONEncoder.piqley.encode(workflow)
        let decoded = try JSONDecoder.piqley.decode(Workflow.self, from: data)
        #expect(decoded.pipeline["publish"] == ["ghost"])
        #expect(decoded.name == "test")
    }
}
