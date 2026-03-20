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
        #expect(result.namespace["TIFF:Model"] == .string("Sony"))
        #expect(result.namespace["IPTC:Keywords"] == .array([.string("landscape")]))
        #expect(result.namespace["existing"] == .string("preserved"))
    }

    @Test("clone overwrites existing value")
    func cloneOverwrites() async throws {
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
        #expect(result.namespace["keywords"] == .array([.string("new-value")]))
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

    // MARK: - WriteBack compilation

    @Test("writeBack action compiles without error")
    func testWriteBackCompiles() throws {
        let rules = [Rule(
            match: MatchConfig(field: "original:TIFF:Model", pattern: "glob:*"),
            emit: [EmitConfig(action: nil, field: "keywords", values: ["test"], replacements: nil, source: nil)],
            write: [EmitConfig(action: "writeBack", field: nil, values: nil, replacements: nil, source: nil)]
        )]
        let evaluator = try RuleEvaluator(rules: rules, logger: logger)
        #expect(evaluator.compiledRules.count == 1)
        #expect(evaluator.compiledRules[0].writeActions.count == 1)
        if case .writeBack = evaluator.compiledRules[0].writeActions[0] {
            // expected
        } else {
            Issue.record("Expected writeBack action")
        }
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
}
