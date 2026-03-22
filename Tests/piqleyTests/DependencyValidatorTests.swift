import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("DependencyValidator")
struct DependencyValidatorTests {
    // Helper to make a manifest with optional dependencies.
    // identifier defaults to the plugin name (short form) for test simplicity.
    private func manifest(name: String, hook: String, dependencies: [String]? = nil) -> PluginManifest {
        PluginManifest(
            identifier: name,
            name: name,
            pluginSchemaVersion: "1",
            dependencies: dependencies?.map { PluginDependency(name: $0) }
        )
    }

    @Test("no dependencies passes validation")
    func testNoDependencies() throws {
        let manifests = [manifest(name: "a", hook: "publish")]
        let pipeline: [String: [String]] = ["publish": ["a"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result == nil)
    }

    @Test("original dependency always passes")
    func testOriginalDependency() throws {
        let manifests = [manifest(name: "a", hook: "publish", dependencies: ["original"])]
        let pipeline: [String: [String]] = ["publish": ["a"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result == nil)
    }

    @Test("valid same-hook dependency passes")
    func testSameHookDependency() throws {
        let manifests = [
            manifest(name: "hashtag", hook: "post-process"),
            manifest(name: "flickr", hook: "post-process", dependencies: ["hashtag"]),
        ]
        let pipeline: [String: [String]] = ["post-process": ["hashtag", "flickr"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result == nil)
    }

    @Test("valid cross-hook dependency passes")
    func testCrossHookDependency() throws {
        let manifests = [
            manifest(name: "hashtag", hook: "post-process"),
            manifest(name: "flickr", hook: "publish", dependencies: ["hashtag"]),
        ]
        let pipeline: [String: [String]] = [
            "post-process": ["hashtag"],
            "publish": ["flickr"],
        ]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result == nil)
    }

    @Test("dependency on later plugin in same hook fails")
    func testSameHookWrongOrder() throws {
        let manifests = [
            manifest(name: "flickr", hook: "post-process", dependencies: ["hashtag"]),
            manifest(name: "hashtag", hook: "post-process"),
        ]
        let pipeline: [String: [String]] = ["post-process": ["flickr", "hashtag"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result != nil)
        #expect(result!.contains("hashtag"))
    }

    @Test("dependency on plugin in later hook fails")
    func testLaterHookDependency() throws {
        let manifests = [
            manifest(name: "hashtag", hook: "pre-process", dependencies: ["flickr"]),
            manifest(name: "flickr", hook: "publish"),
        ]
        let pipeline: [String: [String]] = [
            "pre-process": ["hashtag"],
            "publish": ["flickr"],
        ]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result != nil)
    }

    @Test("dependency on nonexistent plugin fails")
    func testMissingDependency() throws {
        let manifests = [
            manifest(name: "flickr", hook: "publish", dependencies: ["ghost"]),
        ]
        let pipeline: [String: [String]] = ["publish": ["flickr"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result != nil)
        #expect(result!.contains("ghost"))
    }

    @Test("plugin named original is rejected")
    func testOriginalNameRejected() throws {
        let manifests = [manifest(name: "original", hook: "publish")]
        let pipeline: [String: [String]] = ["publish": ["original"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result != nil)
        #expect(result!.contains("reserved"))
    }

    @Test("plugin named skip is rejected")
    func testSkipNameRejected() throws {
        let manifests = [manifest(name: "skip", hook: "publish")]
        let pipeline: [String: [String]] = ["publish": ["skip"]]
        let result = DependencyValidator.validate(manifests: manifests, pipeline: pipeline, stageOrder: Hook.defaultStageNames)
        #expect(result != nil)
        #expect(result!.contains("reserved"))
    }
}
