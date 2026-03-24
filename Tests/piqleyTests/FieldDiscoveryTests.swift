import Foundation
import Testing
import PiqleyCore
@testable import piqley

@Suite("FieldDiscovery")
struct FieldDiscoveryTests {

    // MARK: - original source

    @Test("original key contains fields from catalog")
    func originalKeyContainsFields() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let originalFields = result["original"]
        #expect(originalFields != nil)
        #expect(originalFields?.isEmpty == false)
    }

    // MARK: - read source

    @Test("read key is present and non-empty")
    func readKeyPresent() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let readFields = result["read"]
        #expect(readFields != nil)
        #expect(readFields?.isEmpty == false)
    }

    // MARK: - dependency fields

    @Test("dependency plugin fields appear under plugin identifier key")
    func dependencyFieldsKeyedByIdentifier() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "com.example.myplugin",
            fields: ["AlbumName", "CameraSerial"]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let depFields = result["com.example.myplugin"]
        #expect(depFields != nil)
        #expect(depFields?.count == 2)
    }

    @Test("dependency fields have custom category")
    func dependencyFieldsAreCustomCategory() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "exif-tagger",
            fields: ["scene"]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let field = result["exif-tagger"]?.first
        #expect(field?.category == .custom)
        #expect(field?.source == "exif-tagger")
    }

    @Test("dependency fields are sorted alphabetically")
    func dependencyFieldsSortedAlphabetically() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "com.example.plugin",
            fields: ["Zebra", "Alpha", "Middle"]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let names = result["com.example.plugin"]?.map(\.name) ?? []
        #expect(names == ["Alpha", "Middle", "Zebra"])
    }

    @Test("multiple dependencies each get their own key")
    func multipleDependenciesEachGetOwnKey() {
        let dep1 = FieldDiscovery.DependencyInfo(identifier: "plugin.a", fields: ["FieldA"])
        let dep2 = FieldDiscovery.DependencyInfo(identifier: "plugin.b", fields: ["FieldB"])
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep1, dep2])
        #expect(result["plugin.a"] != nil)
        #expect(result["plugin.b"] != nil)
    }

    @Test("result always contains original and read keys")
    func alwaysContainsOriginalAndRead() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        #expect(result.keys.contains("original"))
        #expect(result.keys.contains("read"))
    }

    @Test("no dependencies: result has exactly two keys")
    func noDependenciesResultHasTwoKeys() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        #expect(result.count == 2)
    }

    // MARK: - Upstream field discovery

    private func createRulesFile(
        at baseDir: URL,
        pluginId: String,
        stageName: String,
        emitFields: [String]
    ) throws {
        let pluginDir = baseDir.appendingPathComponent(pluginId)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let rules: [[String: Any]] = emitFields.map { field in
            [
                "match": ["field": "original:IPTC:Keywords", "pattern": "glob:*"],
                "emit": [["field": field, "values": ["test"]]],
                "write": []
            ]
        }
        let stageConfig: [String: Any] = ["preRules": rules]
        let data = try JSONSerialization.data(withJSONObject: stageConfig)
        let file = pluginDir.appendingPathComponent("stage-\(stageName).json")
        try data.write(to: file)
    }

    @Test("discovers emit fields from upstream plugin rules")
    func discoversUpstreamEmitFields() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try createRulesFile(
            at: tmpDir, pluginId: "plugin.upstream",
            stageName: "pre-process", emitFields: ["IPTC:Keywords", "score"]
        )

        let pipeline: [String: [String]] = [
            "pre-process": ["plugin.upstream"],
            "publish": ["plugin.target"]
        ]
        let stageOrder = ["pre-process", "publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.target",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        let upstream = deps.first { $0.identifier == "plugin.upstream" }
        #expect(upstream != nil)
        #expect(Set(upstream?.fields ?? []) == Set(["IPTC:Keywords", "score"]))
    }

    @Test("includes self-emitted fields")
    func includesSelfEmittedFields() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try createRulesFile(
            at: tmpDir, pluginId: "plugin.target",
            stageName: "publish", emitFields: ["tags"]
        )

        let pipeline: [String: [String]] = [
            "publish": ["plugin.target"]
        ]
        let stageOrder = ["publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.target",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        let selfDep = deps.first { $0.identifier == "plugin.target" }
        #expect(selfDep != nil)
        #expect(selfDep?.fields == ["tags"])
    }

    @Test("same-stage plugin earlier in array is upstream")
    func sameStageEarlierPluginIsUpstream() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try createRulesFile(
            at: tmpDir, pluginId: "plugin.first",
            stageName: "publish", emitFields: ["title"]
        )

        let pipeline: [String: [String]] = [
            "publish": ["plugin.first", "plugin.second"]
        ]
        let stageOrder = ["publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.second",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        let first = deps.first { $0.identifier == "plugin.first" }
        #expect(first != nil)
        #expect(first?.fields == ["title"])
    }

    @Test("only harvests from upstream stages, not later stages")
    func onlyHarvestsUpstreamStages() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Plugin appears in both pre-process and post-publish
        try createRulesFile(
            at: tmpDir, pluginId: "plugin.multi",
            stageName: "pre-process", emitFields: ["upstream-field"]
        )
        try createRulesFile(
            at: tmpDir, pluginId: "plugin.multi",
            stageName: "post-publish", emitFields: ["downstream-field"]
        )

        let pipeline: [String: [String]] = [
            "pre-process": ["plugin.multi"],
            "publish": ["plugin.target"],
            "post-publish": ["plugin.multi"]
        ]
        let stageOrder = ["pre-process", "publish", "post-publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.target",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        let multi = deps.first { $0.identifier == "plugin.multi" }
        #expect(multi != nil)
        #expect(multi?.fields == ["upstream-field"])
        // downstream-field should NOT appear
    }

    @Test("excludes nil and wildcard emit fields")
    func excludesNilAndWildcardFields() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pluginDir = tmpDir.appendingPathComponent("plugin.upstream")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // Manually build JSON with skip (nil field) and clone wildcard
        let json: [String: Any] = [
            "preRules": [
                [
                    "match": ["field": "original:IPTC:Keywords", "pattern": "glob:*"],
                    "emit": [
                        ["field": "good-field", "values": ["test"]],
                        ["action": "skip"],
                        ["action": "clone", "field": "*", "source": "original"]
                    ],
                    "write": []
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))

        let pipeline: [String: [String]] = [
            "pre-process": ["plugin.upstream"],
            "publish": ["plugin.target"]
        ]
        let stageOrder = ["pre-process", "publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.target",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        let upstream = deps.first { $0.identifier == "plugin.upstream" }
        #expect(upstream?.fields == ["good-field"])
    }

    @Test("missing rules directory produces no dependency")
    func missingRulesDirProducesNoDep() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let pipeline: [String: [String]] = [
            "pre-process": ["plugin.upstream"],
            "publish": ["plugin.target"]
        ]
        let stageOrder = ["pre-process", "publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.target",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        #expect(deps.isEmpty)
    }

    @Test("harvests from postRules as well as preRules")
    func harvestsFromPostRules() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pluginDir = tmpDir.appendingPathComponent("plugin.upstream")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "postRules": [
                [
                    "match": ["field": "original:IPTC:Keywords", "pattern": "glob:*"],
                    "emit": [["field": "post-field", "values": ["test"]]],
                    "write": []
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: pluginDir.appendingPathComponent("stage-pre-process.json"))

        let pipeline: [String: [String]] = [
            "pre-process": ["plugin.upstream"],
            "publish": ["plugin.target"]
        ]
        let stageOrder = ["pre-process", "publish"]

        let deps = FieldDiscovery.discoverUpstreamFields(
            pipeline: pipeline,
            targetPlugin: "plugin.target",
            stageOrder: stageOrder,
            rulesBaseDir: tmpDir
        )

        let upstream = deps.first { $0.identifier == "plugin.upstream" }
        #expect(upstream?.fields == ["post-field"])
    }
}
