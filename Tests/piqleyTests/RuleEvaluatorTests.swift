import Testing
import Foundation
import Logging
import PiqleyCore
@testable import piqley

@Suite("RuleEvaluator")
struct RuleEvaluatorTests {
    private let logger = Logger(label: "test.rule-evaluator")

    private func makeRule(
        hook: String? = nil,
        field: String = "original:TIFF:Model",
        pattern: String = "Sony",
        emit: [EmitConfig] = [EmitConfig(field: "keywords", values: ["sony"])]
    ) -> Rule {
        Rule(
            match: MatchConfig(hook: hook, field: field, pattern: pattern),
            emit: emit
        )
    }

    // MARK: - Basic matching (add action, same as before)

    @Test("exact match on string field")
    func exactMatchString() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "Sony")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
    }

    @Test("glob match on string field")
    func globMatchString() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "glob:Sony*")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony A7R IV")]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
    }

    @Test("regex match on string field")
    func regexMatchString() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "regex:.*a7r.*")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("ILCE-A7R4")]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
    }

    @Test("array field: element-wise matching")
    func arrayFieldElementWise() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(field: "original:IPTC:Keywords", pattern: "landscape")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["IPTC:Keywords": .array([.string("portrait"), .string("landscape")])]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
    }

    @Test("array field: non-string elements skipped")
    func arrayFieldNonStringSkipped() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(field: "original:tags", pattern: "landscape")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["tags": .array([.number(42), .bool(true)])]]
        )
        #expect(result.isEmpty)
    }

    @Test("no match: empty output")
    func noMatchEmptyOutput() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "Canon")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.isEmpty)
    }

    @Test("multiple rules: additive, deduplicated")
    func multipleRulesAdditiveDeduplicated() throws {
        let evaluator = try RuleEvaluator(
            rules: [
                makeRule(pattern: "Sony", emit: [EmitConfig(field: "keywords", values: ["sony", "camera"])]),
                makeRule(pattern: "glob:Sony*", emit: [EmitConfig(field: "keywords", values: ["sony", "mirrorless"])]),
            ],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        // First rule emits ["sony", "camera"], second adds "mirrorless" (sony already present)
        #expect(result["keywords"] == .array([.string("sony"), .string("camera"), .string("mirrorless")]))
    }

    @Test("multiple emit fields")
    func multipleEmitFields() throws {
        let evaluator = try RuleEvaluator(
            rules: [
                makeRule(pattern: "Sony", emit: [EmitConfig(field: "keywords", values: ["sony"])]),
                makeRule(pattern: "Sony", emit: [EmitConfig(field: "tags", values: ["camera-brand"])]),
            ],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
        #expect(result["tags"] == .array([.string("camera-brand")]))
    }

    @Test("hook filtering: rule for post-process skipped at pre-process")
    func hookFiltering() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(hook: "post-process", pattern: "Sony")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result.isEmpty)
    }

    @Test("hook defaulting: rule with no hook evaluates at pre-process")
    func hookDefaulting() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(hook: nil, pattern: "Sony")],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
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
    func invalidRegexSkippedNonInteractive() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "regex:[invalid")],
            nonInteractive: true,
            logger: logger
        )
        #expect(evaluator.compiledRules.isEmpty)
    }

    @Test("unknown hook throws in interactive mode")
    func unknownHookThrows() {
        #expect(throws: RuleCompilationError.self) {
            try RuleEvaluator(
                rules: [makeRule(hook: "not-a-real-hook", pattern: "Sony")],
                logger: logger
            )
        }
    }

    // MARK: - Remove action

    @Test("remove action filters matching values")
    func removeAction() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["old-tag", "glob:auto-*"])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-tag"), .string("auto-focus"), .string("keeper")])]
        )
        #expect(result["keywords"] == .array([.string("keeper")]))
    }

    @Test("remove is case-insensitive for exact matches")
    func removeCaseInsensitive() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["Old-Tag"])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-tag"), .string("keeper")])]
        )
        #expect(result["keywords"] == .array([.string("keeper")]))
    }

    @Test("remove all values removes the field entirely")
    func removeAllValuesRemovesField() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "remove", field: "keywords", values: ["glob:*"])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("a"), .string("b")])]
        )
        #expect(result["keywords"] == nil)
    }

    // MARK: - Replace action

    @Test("replace action substitutes matching values")
    func replaceAction() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                    Replacement(pattern: "regex:SONY(.+)", replacement: "Sony $1"),
                ])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5"), .string("keeper")])]
        )
        #expect(result["keywords"] == .array([.string("Sony A7R5"), .string("keeper")]))
    }

    @Test("replace first match wins")
    func replaceFirstMatchWins() throws {
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
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
        )
        // Exact match wins over regex
        #expect(result["keywords"] == .array([.string("Sony A7R V")]))
    }

    @Test("replace whole-match only: partial match does not replace")
    func replaceWholeMatchOnly() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "replace", field: "keywords", replacements: [
                    Replacement(pattern: "regex:SONY", replacement: "Sony"),
                ])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("SONYA7R5")])]
        )
        // "SONY" doesn't whole-match "SONYA7R5", so no replacement
        #expect(result["keywords"] == .array([.string("SONYA7R5")]))
    }

    // MARK: - RemoveField action

    @Test("removeField action removes a field")
    func removeFieldAction() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "keywords")]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old")]), "tags": .array([.string("kept")])]
        )
        #expect(result["keywords"] == nil)
        #expect(result["tags"] == .array([.string("kept")]))
    }

    @Test("removeField with wildcard removes all fields")
    func removeFieldWildcard() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(action: "removeField", field: "*")]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("a")]), "tags": .array([.string("b")])]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Multi-action and namespace preservation

    @Test("multiple emit actions in one rule applied in order")
    func multipleEmitActionsInOrder() throws {
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
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["keywords": .array([.string("old-stuff")])]
        )
        #expect(result["keywords"] == .array([.string("fresh-start")]))
    }

    @Test("untouched fields preserved in output")
    func untouchedFieldsPreserved() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(field: "keywords", values: ["sony"])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
            currentNamespace: ["existing": .string("preserved")]
        )
        #expect(result["existing"] == .string("preserved"))
        #expect(result["keywords"] == .array([.string("sony")]))
    }

    @Test("add deduplicates against currentNamespace")
    func addDeduplicatesAgainstExisting() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(
                pattern: "Sony",
                emit: [EmitConfig(field: "keywords", values: ["sony", "new"])]
            )],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]],
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
