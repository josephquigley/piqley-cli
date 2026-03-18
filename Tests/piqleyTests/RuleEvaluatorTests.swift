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
        emitField: String? = nil,
        emitValues: [String] = ["sony"]
    ) -> Rule {
        Rule(
            match: MatchConfig(hook: hook, field: field, pattern: pattern),
            emit: EmitConfig(field: emitField, values: emitValues)
        )
    }

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
                makeRule(pattern: "Sony", emitValues: ["sony", "camera"]),
                makeRule(pattern: "glob:Sony*", emitValues: ["sony", "mirrorless"]),
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
                makeRule(pattern: "Sony", emitField: "keywords", emitValues: ["sony"]),
                makeRule(pattern: "Sony", emitField: "tags", emitValues: ["camera-brand"]),
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

    @Test("emit.field defaults to keywords")
    func emitFieldDefaultsToKeywords() throws {
        let evaluator = try RuleEvaluator(
            rules: [makeRule(pattern: "Sony", emitField: nil, emitValues: ["sony"])],
            logger: logger
        )
        let result = evaluator.evaluate(
            hook: "pre-process",
            state: ["original": ["TIFF:Model": .string("Sony")]]
        )
        #expect(result["keywords"] == .array([.string("sony")]))
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
}
