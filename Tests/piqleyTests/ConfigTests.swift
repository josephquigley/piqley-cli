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
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
        #expect(workflow.name == "test")
        #expect(workflow.pipeline["pre-process"] == ["piqley-metadata", "piqley-resize"])
        #expect(workflow.pipeline["publish"] == ["ghost"])
    }

    @Test("empty workflow has all six hooks")
    func testEmptyWorkflow() {
        let workflow = Workflow.empty(name: "default", activeStages: Hook.defaultStageNames)
        #expect(workflow.pipeline.count == 6)
        #expect(workflow.pipeline["pipeline-start"] == [])
        #expect(workflow.pipeline["pre-process"] == [])
        #expect(workflow.pipeline["post-process"] == [])
        #expect(workflow.pipeline["publish"] == [])
        #expect(workflow.pipeline["post-publish"] == [])
        #expect(workflow.pipeline["pipeline-finished"] == [])
    }

    @Test("encodes and decodes round-trip")
    func testRoundTrip() throws {
        var workflow = Workflow.empty(name: "test", displayName: "Test", activeStages: Hook.defaultStageNames)
        workflow.pipeline["publish"] = ["ghost"]
        let data = try JSONEncoder().encode(workflow)
        let decoded = try JSONDecoder().decode(Workflow.self, from: data)
        #expect(decoded.pipeline["publish"] == ["ghost"])
        #expect(decoded.name == "test")
    }
}
