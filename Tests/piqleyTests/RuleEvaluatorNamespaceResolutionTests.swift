import Testing
import Foundation
import Logging
import PiqleyCore
@testable import piqley

@Suite("RuleEvaluator auto-namespace resolution")
struct RuleEvaluatorNamespaceResolutionTests {
    private let logger = Logger(label: "test.namespace-resolution")

    @Test("foreign namespace data resolved via referencedNamespaces")
    func testForeignNamespaceCloneResolution() async throws {
        let stateStore = StateStore()

        // Populate state: a foreign plugin has already written keywords for this image
        await stateStore.setNamespace(
            image: "photo.jpg",
            plugin: "foreign.plugin",
            values: ["keywords": .array([.string("tag1"), .string("tag2")])]
        )

        // Rule matches on foreign.plugin:keywords and clones it to "tags"
        let rule = Rule(
            match: MatchConfig(field: "foreign.plugin:keywords", pattern: "glob:*"),
            emit: [
                EmitConfig(action: "clone", field: "tags", values: nil, replacements: nil, source: "foreign.plugin:keywords")
            ]
        )

        let evaluator = try RuleEvaluator(
            rules: [rule],
            pluginId: "com.test.consumer",
            logger: logger
        )

        // Verify referencedNamespaces includes the foreign plugin
        #expect(evaluator.referencedNamespaces.contains("foreign.plugin"))

        // Resolve state using manifestDeps (empty) + ruleDeps, mimicking evaluateRuleset
        let ruleDeps = Array(evaluator.referencedNamespaces)
        let manifestDeps: [String] = []
        let resolved = await stateStore.resolve(
            image: "photo.jpg",
            dependencies: manifestDeps + ruleDeps + [ReservedName.original, "com.test.consumer", ReservedName.skip]
        )

        // Evaluate with the resolved state
        let result = await evaluator.evaluate(
            state: resolved,
            currentNamespace: [:],
            imageName: "photo.jpg",
            pluginId: "com.test.consumer",
            stateStore: stateStore
        )

        // The cloned tags should appear in the output
        #expect(result.namespace["tags"] == .array([.string("tag1"), .string("tag2")]))
    }

    @Test("foreign namespace not resolved without referencedNamespaces")
    func testForeignNamespaceNotResolvedWithoutRuleDeps() async throws {
        let stateStore = StateStore()

        await stateStore.setNamespace(
            image: "photo.jpg",
            plugin: "foreign.plugin",
            values: ["keywords": .array([.string("tag1"), .string("tag2")])]
        )

        let rule = Rule(
            match: MatchConfig(field: "foreign.plugin:keywords", pattern: "glob:*"),
            emit: [
                EmitConfig(action: "clone", field: "tags", values: nil, replacements: nil, source: "foreign.plugin:keywords")
            ]
        )

        let evaluator = try RuleEvaluator(
            rules: [rule],
            pluginId: "com.test.consumer",
            logger: logger
        )

        // Resolve state WITHOUT ruleDeps, simulating the old behavior
        let manifestDeps: [String] = []
        let resolved = await stateStore.resolve(
            image: "photo.jpg",
            dependencies: manifestDeps + [ReservedName.original, "com.test.consumer", ReservedName.skip]
        )

        let result = await evaluator.evaluate(
            state: resolved,
            currentNamespace: [:],
            imageName: "photo.jpg",
            pluginId: "com.test.consumer",
            stateStore: stateStore
        )

        // Without the foreign namespace in dependencies, the clone has no source data
        #expect(result.namespace["tags"] == nil)
    }
}
