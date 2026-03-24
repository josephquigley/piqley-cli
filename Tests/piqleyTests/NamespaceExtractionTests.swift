import Testing
import PiqleyCore
@testable import piqley

@Suite("NamespaceExtraction")
struct NamespaceExtractionTests {

    // MARK: - extractReferencedNamespaces

    @Test("extracts namespace from match field")
    func extractsFromMatchField() {
        let rule = Rule(
            match: MatchConfig(field: "original:EXIF:ISO", pattern: "100"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["low-iso"], replacements: nil, source: nil)]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.contains("original"))
    }

    @Test("extracts namespace from emit clone source")
    func extractsFromEmitCloneSource() {
        let rule = Rule(
            match: MatchConfig(field: "original:EXIF:ISO", pattern: "100"),
            emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "com.example.tagger:tags")]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.contains("com.example.tagger"))
    }

    @Test("extracts namespace from write clone source")
    func extractsFromWriteCloneSource() {
        let rule = Rule(
            match: MatchConfig(field: "read:IPTC:Keywords", pattern: "landscape"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["nature"], replacements: nil, source: nil)],
            write: [EmitConfig(action: "clone", field: "IPTC:Keywords", values: nil, replacements: nil, source: "plugin.a:outputField")]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.contains("plugin.a"))
    }

    @Test("collects namespaces across multiple stages and slots")
    func collectsAcrossStagesAndSlots() {
        let rule1 = Rule(
            match: MatchConfig(field: "plugin.a:field1", pattern: "x"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["a"], replacements: nil, source: nil)]
        )
        let rule2 = Rule(
            match: MatchConfig(field: "plugin.b:field2", pattern: "y"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["b"], replacements: nil, source: nil)]
        )
        let stages: [String: StageConfig] = [
            "pre-process": StageConfig(preRules: [rule1], binary: nil, postRules: nil),
            "post-process": StageConfig(preRules: nil, binary: nil, postRules: [rule2]),
        ]
        let result = RulesWizard.extractReferencedNamespaces(from: stages)
        #expect(result.contains("plugin.a"))
        #expect(result.contains("plugin.b"))
    }

    @Test("returns empty set when no rules exist")
    func emptyWhenNoRules() {
        let stages: [String: StageConfig] = [
            "pre-process": StageConfig(preRules: nil, binary: nil, postRules: nil),
        ]
        let result = RulesWizard.extractReferencedNamespaces(from: stages)
        #expect(result.isEmpty)
    }

    // MARK: - nonDependencyNamespaces

    @Test("filters out built-in namespaces and dependencies")
    func filtersBuiltInsAndDependencies() {
        let allNamespaces: Set<String> = ["original", "read", "plugin.a", "plugin.b"]
        let dependencies: Set<String> = ["plugin.a"]
        let result = RulesWizard.nonDependencyNamespaces(allNamespaces, dependencies: dependencies)
        #expect(result == ["plugin.b"])
    }

    @Test("returns empty when all namespaces are built-in or dependencies")
    func emptyWhenAllAccountedFor() {
        let allNamespaces: Set<String> = ["original", "read", "plugin.a"]
        let dependencies: Set<String> = ["plugin.a"]
        let result = RulesWizard.nonDependencyNamespaces(allNamespaces, dependencies: dependencies)
        #expect(result.isEmpty)
    }

    @Test("returns all plugin namespaces when no dependencies declared")
    func allPluginNamespacesWhenNoDeps() {
        let allNamespaces: Set<String> = ["original", "read", "plugin.a", "plugin.b"]
        let dependencies: Set<String> = []
        let result = RulesWizard.nonDependencyNamespaces(allNamespaces, dependencies: dependencies)
        #expect(result == ["plugin.a", "plugin.b"])
    }

    @Test("match field without colon produces no namespace")
    func matchFieldWithoutColon() {
        let rule = Rule(
            match: MatchConfig(field: "keywords", pattern: "test"),
            emit: [EmitConfig(action: "add", field: "keywords", values: ["x"], replacements: nil, source: nil)]
        )
        let result = RulesWizard.extractReferencedNamespaces(from: ["stage": StageConfig(preRules: [rule], binary: nil, postRules: nil)])
        #expect(result.isEmpty)
    }
}
