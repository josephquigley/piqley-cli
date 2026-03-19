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
        emit: [EmitConfig] = [EmitConfig(field: "keywords", values: ["sony"])]
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
        #expect(result["keywords"] == .array([.string("sony")]))
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
        #expect(result["keywords"] == .array([.string("sony")]))
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
        #expect(result["keywords"] == .array([.string("sony")]))
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
        #expect(result["keywords"] == .array([.string("sony")]))
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
        #expect(result.isEmpty)
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
        #expect(result.isEmpty)
    }

    @Test("multiple rules: additive, deduplicated")
    func multipleRulesAdditiveDeduplicated() async throws {
        let evaluator = try RuleEvaluator(
            rules: [
                makeRule(pattern: "Sony", emit: [EmitConfig(field: "keywords", values: ["sony", "camera"])]),
                makeRule(pattern: "glob:Sony*", emit: [EmitConfig(field: "keywords", values: ["sony", "mirrorless"])]),
            ],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        // First rule emits ["sony", "camera"], second adds "mirrorless" (sony already present)
        #expect(result["keywords"] == .array([.string("sony"), .string("camera"), .string("mirrorless")]))
    }

    @Test("multiple emit fields")
    func multipleEmitFields() async throws {
        let evaluator = try RuleEvaluator(
            rules: [
                makeRule(pattern: "Sony", emit: [EmitConfig(field: "keywords", values: ["sony"])]),
                makeRule(pattern: "Sony", emit: [EmitConfig(field: "tags", values: ["camera-brand"])]),
            ],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
        #expect(result["tags"] == .array([.string("camera-brand")]))
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
        #expect(result["keywords"] == .array([.string("sony")]))
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
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["old-tag", "glob:auto-*"])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-tag"), .string("auto-focus"), .string("keeper")])]
        )
        #expect(result["keywords"] == .array([.string("keeper")]))
    }

    @Test("remove is case-insensitive for exact matches")
    func removeCaseInsensitive() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["Old-Tag"])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-tag"), .string("keeper")])]
        )
        #expect(result["keywords"] == .array([.string("keeper")]))
    }

    @Test("remove all values removes the field entirely")
    func removeAllValuesRemovesField() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["glob:*"])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("a"), .string("b")])]
        )
        #expect(result["keywords"] == nil)
    }

    // MARK: - Replace action

    @Test("replace action substitutes matching values")
    func replaceAction() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                    Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1"),
                ])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5"), .string("keeper")])]
        )
        #expect(result["keywords"] == .array([.string("Sony A7R5"), .string("keeper")]))
    }

    @Test("replace first match wins")
    func replaceFirstMatchWins() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                    Replacement(pattern: "SONYA7R5", replacement: "Sony A7R V"),
                    Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1"),
                ])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
        )
        // Exact match wins over regex
        #expect(result["keywords"] == .array([.string("Sony A7R V")]))
    }

    @Test("replace whole-match only: partial match does not replace")
    func replaceWholeMatchOnly() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                    Replacement(pattern: "regex:SONY", replacement: "Sony"),
                ])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
        )
        // "SONY" doesn't whole-match "SONYA7R5", so no replacement
        #expect(result["keywords"] == .array([.string("SONYA7R5")]))
    }

    // MARK: - RemoveField action

    @Test("removeField action removes a field")
    func removeFieldAction() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "keywords")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old")]), "tags": .array([.string("kept")])]
        )
        #expect(result["keywords"] == nil)
        #expect(result["tags"] == .array([.string("kept")]))
    }

    @Test("removeField with wildcard removes all fields")
    func removeFieldWildcard() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "*")]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("a")]), "tags": .array([.string("b")])]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Multi-action and namespace preservation

    @Test("multiple emit actions in one rule applied in order")
    func multipleEmitActionsInOrder() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [
                    EmitConfig(action: "removeField", field: "keywords"),
                    EmitConfig(field: "keywords", values: ["fresh-start"]),
                ]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-stuff")])]
        )
        #expect(result["keywords"] == .array([.string("fresh-start")]))
    }

    @Test("untouched fields preserved in output")
    func untouchedFieldsPreserved() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(field: "keywords", values: ["sony"])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["existing": .string("preserved")]
        )
        #expect(result["existing"] == .string("preserved"))
        #expect(result["keywords"] == .array([.string("sony")]))
    }

    @Test("add deduplicates against currentNamespace")
    func addDeduplicatesAgainstExisting() async throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(field: "keywords", values: ["sony", "new"])]
            )],
            logger: logger
        )
        let result = await evaluator.evaluate(
            state:["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("sony")])]
        )
        #expect(result["keywords"] == .array([.string("sony"), .string("new")]))
    }

    // MARK: - Validation errors

    @Test("add with nil values throws")
    func addNilValuesThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(
                    pattern: "Sony",
                    emit: [EmitConfig(action: "add", field: "keywords")]
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
                    emit: [EmitConfig(field: "keywords")]
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
                    emit: [EmitConfig(action: "replace", field: "keywords", values: ["bad"], replacements: [Replacement(pattern: "a", replacement: "b")])]
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
                    emit: [EmitConfig(action: "removeField", field: "keywords", values: ["bad"])]
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
                    emit: [EmitConfig(action: "unknown", field: "keywords", values: ["x"])]
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
                    emit: [EmitConfig(field: "", values: ["x"])]
                )],
                logger: logger
            )
        }
    }
}
