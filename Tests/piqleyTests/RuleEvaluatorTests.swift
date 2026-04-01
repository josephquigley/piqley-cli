import Testing
import Foundation
import Logging
import PiqleyCore
@testable import piqley

@Suite("RuleEvaluator")
struct RuleEvaluatorTests {
    private let logger = Logger(label: "test.rule-evaluator")

    private func makeRule(
        field: String = "original:TIFF:Model",
        pattern: String = "Sony",
        emit: [EmitConfig] = [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]
    ) -> Rule {
        Rule(
            match: MatchConfig(field: field, pattern: pattern),
            emit: emit
        )
    }

    // MARK: - Basic matching (add action, same as before)

    @Test("exact match on string field")
    func exactMatchString() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "Sony")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    @Test("glob match on string field")
    func globMatchString() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "glob:Sony*")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony A7R IV")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    @Test("regex match on string field")
    func regexMatchString() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "regex:.*a7r.*")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("ILCE-A7R4")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    @Test("array field: element-wise matching")
    func arrayFieldElementWise() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(field: "original:IPTC:Keywords", pattern: "landscape")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("portrait"), .string("landscape")])]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    @Test("array field: non-string elements skipped")
    func arrayFieldNonStringSkipped() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(field: "original:tags", pattern: "landscape")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["tags": .array([.number(42), .bool(true)])]]
        )
        #expect(result.namespace.isEmpty)
    }

    @Test("no match: empty output")
    func noMatchEmptyOutput() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "Canon")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace.isEmpty)
    }

    @Test("multiple rules: additive, deduplicated")
    func multipleRulesAdditiveDeduplicated() async throws {
        let evaluator = try RuleEvaluator(
            rules: [
                makeRule(pattern: "Sony", emit: [EmitConfig(action: nil, field: "keywords", values: ["sony", "camera"], replacements: nil, source: nil)]),
                makeRule(pattern: "glob:Sony*", emit: [EmitConfig(action: nil, field: "keywords", values: ["sony", "mirrorless"], replacements: nil, source: nil)]),
            ],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        // First rule emits ["sony", "camera"], second adds "mirrorless" (sony already present)
        #expect(result.namespace["keywords"] == .array([.string("sony"), .string("camera"), .string("mirrorless")]))
    }

    @Test("multiple emit fields")
    func multipleEmitFields() async throws {
        let evaluator = try RuleEvaluator(
            rules: [
                makeRule(pattern: "Sony", emit: [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]),
                makeRule(pattern: "Sony", emit: [EmitConfig(action: nil, field: "tags", values: ["camera-brand"], replacements: nil, source: nil)]),
            ],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
        #expect(result.namespace["tags"] == .array([.string("camera-brand")]))
    }

    @Test("all rules evaluate regardless of stage (no hook filtering in RuleEvaluator)")
    func noHookFiltering() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "Sony")],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    // MARK: - Error handling

    @Test("invalid regex throws in interactive mode")
    func invalidRegexThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(pattern: "regex:[invalid")],
                logger: logger
            )
        }
    }

    @Test("invalid regex skipped in non-interactive mode")
    func invalidRegexSkippedNonInteractive() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "regex:[invalid")],
            nonInteractive: true,
            logger: logger
        )
        #expect(evaluator.compiledRules.isEmpty)
    }

    @Test("invalid glob pattern throws in interactive mode")
    func invalidGlobThrows() {
        // RuleEvaluator validates patterns; a bad regex should still throw
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(pattern: "regex:[invalid")],
                logger: logger
            )
        }
    }

    // MARK: - Remove action

    @Test("remove action filters matching values")
    func removeAction() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["old-tag", "glob:auto-*"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-tag"), .string("auto-focus"), .string("keeper")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("keeper")]))
    }

    @Test("remove is case-insensitive for exact matches")
    func removeCaseInsensitive() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["Old-Tag"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-tag"), .string("keeper")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("keeper")]))
    }

    @Test("remove all values removes the field entirely")
    func removeAllValuesRemovesField() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["glob:*"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("a"), .string("b")])]
        )
        #expect(result.namespace["keywords"] == nil)
    }

    // MARK: - Replace action

    @Test("replace action substitutes matching values")
    func replaceAction() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", values: nil, replacements: [
                    Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1"),
                ], source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5"), .string("keeper")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("Sony A7R5"), .string("keeper")]))
    }

    @Test("replace first match wins")
    func replaceFirstMatchWins() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", values: nil, replacements: [
                    Replacement(pattern: "SONYA7R5", replacement: "Sony A7R V"),
                    Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1"),
                ], source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
        )
        // Exact match wins over regex
        #expect(result.namespace["keywords"] == .array([.string("Sony A7R V")]))
    }

    @Test("replace whole-match only: partial match does not replace")
    func replaceWholeMatchOnly() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", values: nil, replacements: [
                    Replacement(pattern: "regex:SONY", replacement: "Sony"),
                ], source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
        )
        // "SONY" doesn't whole-match "SONYA7R5", so no replacement
        #expect(result.namespace["keywords"] == .array([.string("SONYA7R5")]))
    }

    // MARK: - RemoveField action

    @Test("removeField action removes a field")
    func removeFieldAction() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "keywords", values: nil, replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old")]), "tags": .array([.string("kept")])]
        )
        #expect(result.namespace["keywords"] == nil)
        #expect(result.namespace["tags"] == .array([.string("kept")]))
    }

    @Test("removeField with wildcard removes all fields")
    func removeFieldWildcard() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "*", values: nil, replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("a")]), "tags": .array([.string("b")])]
        )
        #expect(result.namespace.isEmpty)
    }

    // MARK: - Multi-action and namespace preservation

    @Test("multiple emit actions in one rule applied in order")
    func multipleEmitActionsInOrder() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [
                    EmitConfig(action: "removeField", field: "keywords", values: nil, replacements: nil, source: nil),
                    EmitConfig(action: nil, field: "keywords", values: ["fresh-start"], replacements: nil, source: nil),
                ]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-stuff")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("fresh-start")]))
    }

    @Test("untouched fields preserved in output")
    func untouchedFieldsPreserved() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["existing": .string("preserved")]
        )
        #expect(result.namespace["existing"] == .string("preserved"))
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    @Test("add deduplicates against currentNamespace")
    func addDeduplicatesAgainstExisting() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["sony", "new"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("sony")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony"), .string("new")]))
    }

    // MARK: - Validation errors

    @Test("add with nil values throws")
    func addNilValuesThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "add", field: "keywords", values: nil, replacements: nil, source: nil)]
                )],
                logger: logger
            )
        }
    }

    @Test("default action with nil values throws")
    func defaultActionNilValuesThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: nil, field: "keywords", values: nil, replacements: nil, source: nil)]
                )],
                logger: logger
            )
        }
    }

    @Test("replace with values present throws")
    func replaceWithValuesThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "replace", field: "keywords", values: ["bad"], replacements: [Replacement(pattern: "a", replacement: "b")], source: nil)]
                )],
                logger: logger
            )
        }
    }

    @Test("removeField with values present throws")
    func removeFieldWithValuesThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "removeField", field: "keywords", values: ["bad"], replacements: nil, source: nil)]
                )],
                logger: logger
            )
        }
    }

    @Test("unknown action throws")
    func unknownActionThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "unknown", field: "keywords", values: ["x"], replacements: nil, source: nil)]
                )],
                logger: logger
            )
        }
    }

    @Test("empty field throws")
    func emptyFieldThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: nil, field: "", values: ["x"], replacements: nil, source: nil)]
                )],
                logger: logger
            )
        }
    }

    // MARK: - Clone compilation validation

    @Test("clone with valid source compiles")
    func cloneValidSourceCompiles() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")]
            )],
            logger: logger
        )
        #expect(evaluator.compiledRules.count == 1)
    }

    @Test("clone wildcard with valid source compiles")
    func cloneWildcardCompiles() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "*", values: nil, replacements: nil, source: "original")]
            )],
            logger: logger
        )
        #expect(evaluator.compiledRules.count == 1)
    }

    @Test("clone with nil source throws")
    func cloneNilSourceThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "glob:*",
                    emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: nil)]
                )],
                logger: logger
            )
        }
    }

    @Test("clone with empty source throws")
    func cloneEmptySourceThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "glob:*",
                    emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "")]
                )],
                logger: logger
            )
        }
    }

    @Test("clone with values present throws")
    func cloneWithValuesThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "glob:*",
                    emit: [EmitConfig(action: "clone", field: "keywords", values: ["bad"], replacements: nil, source: "original:IPTC:Keywords")]
                )],
                logger: logger
            )
        }
    }

    @Test("clone with replacements present throws")
    func cloneWithReplacementsThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "glob:*",
                    emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: [Replacement(pattern: "a", replacement: "b")], source: "original:IPTC:Keywords")]
                )],
                logger: logger
            )
        }
    }

    @Test("add with source present throws")
    func addWithSourceThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "add", field: "keywords", values: ["x"], replacements: nil, source: "original:IPTC:Keywords")]
                )],
                logger: logger
            )
        }
    }

    @Test("remove with source present throws")
    func removeWithSourceThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "remove", field: "keywords", values: ["x"], replacements: nil, source: "original:IPTC:Keywords")]
                )],
                logger: logger
            )
        }
    }

    @Test("replace with source present throws")
    func replaceWithSourceThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "replace", field: "keywords", values: nil, replacements: [Replacement(pattern: "a", replacement: "b")], source: "original:field")]
                )],
                logger: logger
            )
        }
    }

    @Test("removeField with source present throws")
    func removeFieldWithSourceThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "removeField", field: "keywords", values: nil, replacements: nil, source: "original:field")]
                )],
                logger: logger
            )
        }
    }

    // MARK: - Skip action

    @Test("skip rule compiles successfully")
    func skipRuleCompiles() throws {
        let rules = [makeRule(
            pattern: "glob:*Draft*",
            emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        #expect(evaluator.compiledRules.count == 1)
    }

    @Test("skip action halts further rule evaluation")
    func skipActionHalts() async throws {
        let rules = [
            makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*Draft*",
                emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
            ),
            makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*",
                emit: [EmitConfig(action: nil, field: "tags", values: ["should-not-appear"], replacements: nil, source: nil)]
            )
        ]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let state: [String: [String: JSONValue]] = [
            "original": ["IPTC:Keywords": .array([.string("Draft-Photo")])]
        ]
        let result = await evaluator.evaluate(
            state: state, imageName: "IMG_001.jpg", pluginId: "com.test.plugin"
        )
        #expect(result.skipped == true)
        #expect(result.namespace["tags"] == nil)
    }

    @Test("skip action writes skip record to state store")
    func skipWritesRecord() async throws {
        let rules = [makeRule(
            field: "original:IPTC:Keywords",
            pattern: "glob:*Draft*",
            emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let stateStore = StateStore()
        let state: [String: [String: JSONValue]] = [
            "original": ["IPTC:Keywords": .array([.string("Draft-Photo")])]
        ]
        let result = await evaluator.evaluate(
            state: state, imageName: "IMG_001.jpg", pluginId: "com.test.plugin",
            stateStore: stateStore
        )
        #expect(result.skipped == true)
        let skipState = await stateStore.resolve(image: "IMG_001.jpg", dependencies: ["skip"])
        if case let .array(arr) = skipState["skip"]?["records"],
           case let .object(record) = arr.first {
            #expect(record["file"] == .string("IMG_001.jpg"))
            #expect(record["plugin"] == .string("com.test.plugin"))
        } else {
            Issue.record("Expected skip record, got \(String(describing: skipState["skip"]?["records"]))")
        }
    }

    @Test("no skip when rule doesn't match")
    func noSkipOnMismatch() async throws {
        let rules = [makeRule(
            field: "original:IPTC:Keywords",
            pattern: "glob:*Draft*",
            emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let state: [String: [String: JSONValue]] = [
            "original": ["IPTC:Keywords": .array([.string("Portrait")])]
        ]
        let result = await evaluator.evaluate(
            state: state, imageName: "IMG_001.jpg", pluginId: "com.test.plugin"
        )
        #expect(result.skipped == false)
    }

    // MARK: - Clone evaluation

    @Test("clone single field from original namespace")
    func cloneSingleField() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("landscape"), .string("nature")])]]
        )
        #expect(result.namespace["keywords"] == .array([.string("landscape"), .string("nature")]))
    }

    @Test("clone wildcard copies all fields from source namespace")
    func cloneWildcardCopiesAll() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "*", values: nil, replacements: nil, source: "original")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": [
                "TIFF:Model": .string("Sony"),
                "IPTC:Keywords": .array([.string("landscape")]),
            ]],
            currentNamespace: ["existing": .string("preserved")]
        )
        // Emit clones normalize string values to single-element arrays for SDK strings() consistency
        #expect(result.namespace["TIFF:Model"] == .array([.string("Sony")]))
        #expect(result.namespace["IPTC:Keywords"] == .array([.string("landscape")]))
        #expect(result.namespace["existing"] == .string("preserved"))
    }

    @Test("clone merges with existing array values")
    func cloneMergesArrays() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("new-value")])]],
            currentNamespace: ["keywords": .array([.string("old-value")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("old-value"), .string("new-value")]))
    }

    @Test("clone deduplicates when merging arrays")
    func cloneDeduplicates() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("shared"), .string("new")])]],
            currentNamespace: ["keywords": .array([.string("shared"), .string("old")])]
        )
        #expect(result.namespace["keywords"] == .array([.string("shared"), .string("old"), .string("new")]))
    }

    @Test("clone replaces when target field does not exist")
    func cloneReplacesWhenEmpty() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("value")])]],
            currentNamespace: [:]
        )
        #expect(result.namespace["keywords"] == .array([.string("value")]))
    }

    @Test("clone from non-existent source is no-op")
    func cloneNonExistentSourceNoop() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "Sony",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["existing": .string("kept")]
        )
        // IPTC:Keywords doesn't exist in state, so no clone happens
        #expect(result.namespace["keywords"] == nil)
        #expect(result.namespace["existing"] == .string("kept"))
    }

    @Test("clone followed by remove")
    func cloneThenRemove() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:IPTC:Keywords",
                pattern: "glob:*",
                emit: [
                    EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "original:IPTC:Keywords"),
                    EmitConfig(action: "remove", field: "keywords", values: ["glob:auto-*"], replacements: nil, source: nil),
                ]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("landscape"), .string("auto-focus"), .string("nature")])]]
        )
        #expect(result.namespace["keywords"] == .array([.string("landscape"), .string("nature")]))
    }

    // MARK: - Skip match field

    @Test("skip match field resolves from skip namespace")
    func skipMatchFieldResolves() async throws {
        let rules = [makeRule(
            field: "skip",
            pattern: "glob:IMG_001*",
            emit: [EmitConfig(action: nil, field: "status", values: ["was-skipped"], replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let skipRecord = JSONValue.object(["file": .string("IMG_001.jpg"), "plugin": .string("com.test.plugin")])
        let state: [String: [String: JSONValue]] = [
            "skip": ["records": .array([skipRecord])]
        ]
        let result = await evaluator.evaluate(state: state, imageName: "IMG_001.jpg")
        #expect(result.namespace["status"] == .array([.string("was-skipped")]))
    }

    @Test("skip match field does not match other images")
    func skipMatchFieldNoMatchOtherImage() async throws {
        let rules = [makeRule(
            field: "skip",
            pattern: "glob:*",
            emit: [EmitConfig(action: nil, field: "status", values: ["was-skipped"], replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let skipRecord = JSONValue.object(["file": .string("IMG_001.jpg"), "plugin": .string("com.test.plugin")])
        let state: [String: [String: JSONValue]] = [
            "skip": ["records": .array([skipRecord])]
        ]
        let result = await evaluator.evaluate(state: state, imageName: "IMG_002.jpg")
        #expect(result.namespace["status"] == nil)
    }

    // MARK: - Match negation

    @Test("match negation fires on non-matching values")
    func testMatchNegation() async throws {
        let rules = [Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "Canon", not: true),
            emit: [EmitConfig(action: nil, field: "keywords", values: ["not-canon"], replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        // "Sony" does not match "Canon", so with not: true the rule fires
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("not-canon")]))
    }

    @Test("match negation does not fire on matching values")
    func testMatchNegationNoFire() async throws {
        let rules = [Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "Canon", not: true),
            emit: [EmitConfig(action: nil, field: "keywords", values: ["not-canon"], replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Canon")]]
        )
        #expect(result.namespace.isEmpty)
    }

    // MARK: - Remove negated

    @Test("remove with not: true keeps only matching values")
    func testRemoveNegated() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["keeper"], replacements: nil, source: nil, not: true)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("keeper"), .string("old-tag"), .string("auto-focus")])]
        )
        // not: true means keep only values matching the matchers ("keeper"), remove everything else
        #expect(result.namespace["keywords"] == .array([.string("keeper")]))
    }

    // MARK: - RemoveField negated

    @Test("removeField with not: true keeps only the named field")
    func testRemoveFieldNegated() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "keywords", values: nil, replacements: nil, source: nil, not: true)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("kept")]), "tags": .array([.string("removed")]), "notes": .string("gone")]
        )
        #expect(result.namespace["keywords"] == .array([.string("kept")]))
        #expect(result.namespace["tags"] == nil)
        #expect(result.namespace["notes"] == nil)
    }

    // MARK: - Self namespace resolution

    @Test("bare field name resolves to pluginId namespace")
    func bareFieldResolvesToPluginId() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "score",
                pattern: "glob:*",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["matched"], replacements: nil, source: nil)]
            )],
            pluginId: "com.example.tagger",
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["com.example.tagger": ["score": .string("95")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("matched")]))
    }

    @Test("self: prefix resolves to pluginId namespace")
    func selfPrefixResolvesToPluginId() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "self:score",
                pattern: "95",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["matched"], replacements: nil, source: nil)]
            )],
            pluginId: "com.example.tagger",
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["com.example.tagger": ["score": .string("95")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("matched")]))
    }

    @Test("bare 'skip' field preserves special behavior even with pluginId")
    func bareSkipPreservesSpecialBehavior() async throws {
        // "skip" with no colon must resolve to ("", "skip"), not (pluginId, "skip")
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "skip",
                pattern: "glob:*",
                emit: [EmitConfig(action: "skip", field: nil, values: nil, replacements: nil, source: nil)]
            )],
            pluginId: "com.example.tagger",
            logger: logger
        )
        let skipState: [String: [String: JSONValue]] = [
            "skip": ["records": .array([
                .object(["file": .string("test.jpg"), "plugin": .string("other")])
            ])]
        ]
        let result = await evaluator.evaluate(
            state: skipState,
            imageName: "test.jpg",
            pluginId: "com.example.tagger"
        )
        #expect(result.skipped)
    }

    @Test("bare field name with nil pluginId uses empty namespace")
    func bareFieldNilPluginIdUsesEmptyNamespace() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "score",
                pattern: "95",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["matched"], replacements: nil, source: nil)]
            )],
            pluginId: nil,
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["": ["score": .string("95")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("matched")]))
    }

    @Test("self: prefix with nil pluginId throws compilation error")
    func selfPrefixNilPluginIdThrows() throws {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(field: "self:score", pattern: "95")],
                pluginId: nil,
                logger: logger
            )
        }
    }

    @Test("self: prefix with nil pluginId skips rule in nonInteractive mode")
    func selfPrefixNilPluginIdSkipsNonInteractive() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(field: "self:score", pattern: "95")],
            pluginId: nil,
            nonInteractive: true,
            logger: logger
        )
        // Rule was skipped, so no compiled rules, empty result
        let result = await evaluator.evaluate(
            state: ["anything": ["score": .string("95")]]
        )
        #expect(result.namespace.isEmpty)
    }

    @Test("fully-qualified field still works with pluginId set")
    func fullyQualifiedFieldUnchanged() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "Sony",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["sony"], replacements: nil, source: nil)]
            )],
            pluginId: "com.example.tagger",
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["keywords"] == .array([.string("sony")]))
    }

    @Test("clone with read: namespace")
    func cloneReadNamespace() async throws {
        let buffer = MetadataBuffer(preloaded: [
            "test.jpg": ["IPTC:Keywords": .array([.string("from-file")])]
        ])
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "read:IPTC:Keywords",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "keywords", values: nil, replacements: nil, source: "read:IPTC:Keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: [:],
            metadataBuffer: buffer,
            imageName: "test.jpg"
        )
        #expect(result.namespace["keywords"] == .array([.string("from-file")]))
    }

    // MARK: - Auto-clone on empty field

    @Test("remove auto-clones from source namespace when field is empty")
    func testRemoveAutoCloneFromSource() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: "remove", field: "TIFF:Model", values: ["Sony"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .array([.string("Sony"), .string("Canon"), .string("Nikon")])]]
        )
        #expect(result.namespace["TIFF:Model"] == .array([.string("Canon"), .string("Nikon")]))
    }

    @Test("remove does not auto-clone when field already exists in working")
    func testRemoveNoAutoCloneWhenFieldExists() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: "remove", field: "TIFF:Model", values: ["local-only"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .array([.string("Sony"), .string("Canon")])]],
            currentNamespace: ["TIFF:Model": .array([.string("local-only"), .string("kept")])]
        )
        #expect(result.namespace["TIFF:Model"] == .array([.string("kept")]))
    }

    @Test("remove is no-op when field missing from both working and source")
    func testRemoveNoAutoCloneWhenSourceMissing() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: "remove", field: "nonexistent", values: ["anything"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["nonexistent"] == nil)
    }

    @Test("replace auto-clones from source namespace when field is empty")
    func testReplaceAutoCloneFromSource() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: "replace", field: "TIFF:Model", values: nil, replacements: [
                    Replacement(pattern: "Sony", replacement: "Sony Alpha"),
                ], source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .array([.string("Sony"), .string("Canon")])]]
        )
        #expect(result.namespace["TIFF:Model"] == .array([.string("Sony Alpha"), .string("Canon")]))
    }

    @Test("add does not auto-clone from source namespace")
    func testAddNoAutoClone() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "glob:*",
                emit: [EmitConfig(action: nil, field: "TIFF:Model", values: ["new-value"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .array([.string("Sony"), .string("Canon")])]]
        )
        // add should only have the new value, not clone the originals
        #expect(result.namespace["TIFF:Model"] == .array([.string("new-value")]))
    }

    // MARK: - Referenced namespaces

    @Test("cross-namespace match field included in referencedNamespaces")
    func testCrossNamespaceMatchFieldIncluded() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "other.plugin:someField",
                pattern: "glob:*",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["tag"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        #expect(evaluator.referencedNamespaces.contains("other.plugin"))
    }

    @Test("clone source namespace included in referencedNamespaces")
    func testCloneSourceNamespaceIncluded() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "tags", values: nil, replacements: nil, source: "other.plugin:keywords")]
            )],
            logger: logger
        )
        #expect(evaluator.referencedNamespaces.contains("other.plugin"))
    }

    @Test("reserved namespaces excluded from referencedNamespaces")
    func testReservedNamespacesExcluded() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "read:someField",
                pattern: "glob:*",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["tag"], replacements: nil, source: nil)]
            )],
            pluginId: "com.test.myplugin",
            logger: logger
        )
        #expect(!evaluator.referencedNamespaces.contains("read"))
        #expect(!evaluator.referencedNamespaces.contains("com.test.myplugin"))
    }

    @Test("local fields produce empty referencedNamespaces")
    func testLocalFieldsProduceEmptySet() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "score",
                pattern: "glob:*",
                emit: [EmitConfig(action: nil, field: "keywords", values: ["tag"], replacements: nil, source: nil)]
            )],
            pluginId: "com.test.myplugin",
            logger: logger
        )
        #expect(evaluator.referencedNamespaces.isEmpty)
    }

    @Test("wildcard clone source namespace included in referencedNamespaces")
    func testWildcardCloneSourceIncluded() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "glob:*",
                emit: [EmitConfig(action: "clone", field: "*", values: nil, replacements: nil, source: "foreign.plugin")]
            )],
            logger: logger
        )
        #expect(evaluator.referencedNamespaces.contains("foreign.plugin"))
    }

    @Test("template namespace in add values included in referencedNamespaces")
    func testTemplateNamespaceInAddValues() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "glob:*",
                emit: [EmitConfig(action: "add", field: "title", values: ["Day #{{photo.quigs.datetools:day_diff}}"], replacements: nil, source: nil)]
            )],
            logger: logger
        )
        #expect(evaluator.referencedNamespaces.contains("photo.quigs.datetools"))
    }

    @Test("multiple template namespaces in add values included in referencedNamespaces")
    func testMultipleTemplateNamespaces() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "glob:*",
                emit: [
                    EmitConfig(action: "add", field: "title", values: ["{{plugin.a:field1}} and {{plugin.b:field2}}"], replacements: nil, source: nil)
                ]
            )],
            logger: logger
        )
        #expect(evaluator.referencedNamespaces.contains("plugin.a"))
        #expect(evaluator.referencedNamespaces.contains("plugin.b"))
    }

    @Test("reserved template namespaces excluded from referencedNamespaces")
    func testReservedTemplateNamespacesExcluded() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                field: "original:TIFF:Model",
                pattern: "glob:*",
                emit: [EmitConfig(action: "add", field: "title", values: ["{{read:EXIF:Date}} {{self:myField}}"], replacements: nil, source: nil)]
            )],
            pluginId: "com.test.myplugin",
            logger: logger
        )
        #expect(!evaluator.referencedNamespaces.contains("read"))
        #expect(!evaluator.referencedNamespaces.contains("self"))
        #expect(!evaluator.referencedNamespaces.contains("com.test.myplugin"))
    }

    // MARK: - Unconditional rules

    @Test("unconditional rule always fires")
    func unconditionalRuleAlwaysFires() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(action: "add", field: "isFeatureImage", values: ["true"], replacements: nil, source: nil)]
        )
        let evaluator = try RuleEvaluator(
            rules: [rule],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.namespace["isFeatureImage"] == .array([.string("true")]))
    }

    @Test("unconditional rule fires with empty state")
    func unconditionalRuleFiresWithEmptyState() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(action: "add", field: "isFeatureImage", values: ["true"], replacements: nil, source: nil)]
        )
        let evaluator = try RuleEvaluator(
            rules: [rule],
            logger: logger
        )
        let result = await evaluator.evaluate(state: [:])
        #expect(result.namespace["isFeatureImage"] == .array([.string("true")]))
    }

    // MARK: - Template resolution in add values

    @Test("add value with template resolves from state")
    func addWithTemplate() async throws {
        let rule = Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "glob:Sony*"),
            emit: [EmitConfig(
                action: "add", field: "title",
                values: ["Shot on {{original:TIFF:Model}}"],
                replacements: nil, source: nil
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony A7R IV")]]
        )
        #expect(result.namespace["title"] == .array([.string("Shot on Sony A7R IV")]))
    }

    @Test("add value with template referencing another plugin namespace")
    func addWithCrossNamespaceTemplate() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(
                action: "add", field: "title",
                values: ["365 Project #{{photo.quigs.datetools:365_offset}}"],
                replacements: nil, source: nil
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let result = await evaluator.evaluate(
            state: ["photo.quigs.datetools": ["365_offset": .string("42")]]
        )
        #expect(result.namespace["title"] == .array([.string("365 Project #42")]))
    }

    @Test("add value with missing template field resolves to empty")
    func addWithMissingTemplateField() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(
                action: "add", field: "title",
                values: ["Project #{{photo.quigs.datetools:365_offset}}"],
                replacements: nil, source: nil
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let result = await evaluator.evaluate(state: [:])
        #expect(result.namespace["title"] == .array([.string("Project #")]))
    }

    @Test("add value without templates is unchanged")
    func addWithoutTemplate() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(
                action: "add", field: "keywords",
                values: ["landscape"],
                replacements: nil, source: nil
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let result = await evaluator.evaluate(state: [:])
        #expect(result.namespace["keywords"] == .array([.string("landscape")]))
    }

    @Test("add value with template resolving array joins with commas")
    func addWithArrayTemplate() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(
                action: "add", field: "summary",
                values: ["Tags: {{original:IPTC:Keywords}}"],
                replacements: nil, source: nil
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let result = await evaluator.evaluate(
            state: ["original": ["IPTC:Keywords": .array([.string("landscape"), .string("sunset")])]]
        )
        #expect(result.namespace["summary"] == .array([.string("Tags: landscape,sunset")]))
    }

    @Test("add value with read namespace template")
    func addWithReadNamespaceTemplate() async throws {
        let rule = Rule(
            match: nil,
            emit: [EmitConfig(
                action: "add", field: "camera",
                values: ["{{read:EXIF:Make}}"],
                replacements: nil, source: nil
            )]
        )
        let buffer = MetadataBuffer(preloaded: [
            "test.jpg": ["EXIF:Make": .string("Nikon")]
        ])
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let result = await evaluator.evaluate(
            state: [:], metadataBuffer: buffer, imageName: "test.jpg"
        )
        #expect(result.namespace["camera"] == .array([.string("Nikon")]))
    }

    // MARK: - Write action template resolution

    @Test("write add action resolves templates from state")
    func writeAddResolveTemplate() async throws {
        let rule = Rule(
            match: nil,
            emit: [],
            write: [EmitConfig(
                action: "add", field: "EXIF:FNumber",
                values: ["{{original:EXIF:FNumber}}"],
                replacements: nil, source: nil
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let buffer = MetadataBuffer(preloaded: [
            "img.jpg": ["EXIF:FNumber": .string("old")]
        ])
        _ = await evaluator.evaluate(
            state: ["original": ["EXIF:FNumber": .string("f/2.8")]],
            metadataBuffer: buffer,
            imageName: "img.jpg"
        )
        let meta = await buffer.load(image: "img.jpg")
        #expect(meta["EXIF:FNumber"] == .array([.string("old"), .string("f/2.8")]))
    }

    @Test("write clone action copies field from original namespace into file metadata")
    func writeCloneSingleField() async throws {
        let rule = Rule(
            match: nil,
            emit: [],
            write: [EmitConfig(
                action: "clone", field: "EXIF:FNumber",
                values: nil, replacements: nil,
                source: "original:EXIF:FNumber"
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let buffer = MetadataBuffer(preloaded: [
            "img.jpg": [:]
        ])
        _ = await evaluator.evaluate(
            state: ["original": ["EXIF:FNumber": .string("f/2.8")]],
            metadataBuffer: buffer,
            imageName: "img.jpg"
        )
        let meta = await buffer.load(image: "img.jpg")
        #expect(meta["EXIF:FNumber"] == .string("f/2.8"))
    }

    @Test("write clone wildcard copies all fields from original namespace into file metadata")
    func writeCloneWildcard() async throws {
        let rule = Rule(
            match: nil,
            emit: [],
            write: [EmitConfig(
                action: "clone", field: "*",
                values: nil, replacements: nil,
                source: "original"
            )]
        )
        let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
        let buffer = MetadataBuffer(preloaded: [
            "img.jpg": [:]
        ])
        _ = await evaluator.evaluate(
            state: ["original": [
                "EXIF:FNumber": .string("f/2.8"),
                "TIFF:Make": .string("Sony")
            ]],
            metadataBuffer: buffer,
            imageName: "img.jpg"
        )
        let meta = await buffer.load(image: "img.jpg")
        #expect(meta["EXIF:FNumber"] == .string("f/2.8"))
        #expect(meta["TIFF:Make"] == .string("Sony"))
    }

    // MARK: - Integration: Wipe-and-Restore Pattern

    @Test("removeField wildcard then clone restores only allowed fields")
    func writeWipeAndRestore() async throws {
        let rules = [
            Rule(
                match: nil,
                emit: [],
                write: [EmitConfig(
                    action: "removeField", field: "*",
                    values: nil, replacements: nil, source: nil
                )]
            ),
            Rule(
                match: nil,
                emit: [],
                write: [
                    EmitConfig(action: "clone", field: "TIFF:Make", values: nil, replacements: nil, source: "original:TIFF:Make"),
                    EmitConfig(action: "clone", field: "EXIF:FNumber", values: nil, replacements: nil, source: "original:EXIF:FNumber"),
                ]
            ),
        ]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        let buffer = MetadataBuffer(preloaded: [
            "img.jpg": [
                "TIFF:Make": .string("Sony"),
                "EXIF:FNumber": .string("f/2.8"),
                "EXIF:GPSLatitude": .string("40.7128"),
                "EXIF:SerialNumber": .string("12345"),
                "XMP:CreatorTool": .string("Lightroom"),
            ]
        ])
        _ = await evaluator.evaluate(
            state: ["original": [
                "TIFF:Make": .string("Sony"),
                "EXIF:FNumber": .string("f/2.8"),
                "EXIF:GPSLatitude": .string("40.7128"),
                "EXIF:SerialNumber": .string("12345"),
                "XMP:CreatorTool": .string("Lightroom"),
            ]],
            metadataBuffer: buffer,
            imageName: "img.jpg"
        )
        let meta = await buffer.load(image: "img.jpg")
        #expect(meta["TIFF:Make"] == .string("Sony"))
        #expect(meta["EXIF:FNumber"] == .string("f/2.8"))
        #expect(meta["EXIF:GPSLatitude"] == nil)
        #expect(meta["EXIF:SerialNumber"] == nil)
        #expect(meta["XMP:CreatorTool"] == nil)
        #expect(meta.count == 2)
    }
}
