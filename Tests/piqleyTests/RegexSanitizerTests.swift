import Foundation
import PiqleyCore
import Testing
@testable import piqley

@Suite("RegexSanitizer")
struct RegexSanitizerTests {
    @Test("fixes double-escaped digit class in regex values")
    func fixesDoubleEscapedDigit() {
        let input = "regex:.*\\\\d+mm.*"
        let (result, fixed) = RegexSanitizer.sanitize(input)
        #expect(result == "regex:.*\\d+mm.*")
        #expect(fixed)
    }

    @Test("fixes double-escaped whitespace class in regex values")
    func fixesDoubleEscapedWhitespace() {
        let input = "regex:\\\\s+"
        let (result, fixed) = RegexSanitizer.sanitize(input)
        #expect(result == "regex:\\s+")
        #expect(fixed)
    }

    @Test("fixes multiple double-escaped sequences in one pattern")
    func fixesMultipleDoubleEscapes() {
        let input = "regex:^\\\\d+\\\\+\\\\d+$"
        let (result, fixed) = RegexSanitizer.sanitize(input)
        #expect(result == "regex:^\\d+\\+\\d+$")
        #expect(fixed)
    }

    @Test("leaves correctly escaped regex untouched")
    func leavesCorrectRegexAlone() {
        let input = "regex:.*\\d+mm.*"
        let (result, fixed) = RegexSanitizer.sanitize(input)
        #expect(result == "regex:.*\\d+mm.*")
        #expect(!fixed)
    }

    @Test("leaves non-regex strings untouched")
    func leavesNonRegexAlone() {
        let input = "glob:*Candidate*"
        let (result, fixed) = RegexSanitizer.sanitize(input)
        #expect(result == "glob:*Candidate*")
        #expect(!fixed)
    }

    @Test("leaves literal strings untouched")
    func leavesLiteralAlone() {
        let input = "Negative Lab Pro"
        let (result, fixed) = RegexSanitizer.sanitize(input)
        #expect(result == "Negative Lab Pro")
        #expect(!fixed)
    }

    @Test("sanitizeStageConfig fixes values in emit rules")
    func sanitizesEmitValues() {
        let rule = Rule(
            match: MatchConfig(field: "original:IPTC:Keywords", pattern: "glob:*"),
            emit: [EmitConfig(
                action: "remove", field: "IPTC:Keywords",
                values: ["regex:.*\\\\d+mm.*", "Negative Lab Pro", "regex:^\\\\d+$"],
                replacements: nil, source: nil
            )]
        )
        let stage = StageConfig(preRules: [rule], binary: nil, postRules: nil)

        let (result, didFix) = RegexSanitizer.sanitizeStageConfig(stage)
        #expect(didFix)

        let values = result.preRules![0].emit[0].values!
        #expect(values[0] == "regex:.*\\d+mm.*")
        #expect(values[1] == "Negative Lab Pro")
        #expect(values[2] == "regex:^\\d+$")
    }

    @Test("sanitizeStageConfig fixes match patterns")
    func sanitizesMatchPattern() {
        let rule = Rule(
            match: MatchConfig(field: "EXIF:ISO", pattern: "regex:^\\\\d+$"),
            emit: [EmitConfig(action: nil, field: "tags", values: ["High ISO"], replacements: nil, source: nil)]
        )
        let stage = StageConfig(preRules: [rule], binary: nil, postRules: nil)

        let (result, didFix) = RegexSanitizer.sanitizeStageConfig(stage)
        #expect(didFix)
        #expect(result.preRules![0].match?.pattern == "regex:^\\d+$")
    }

    @Test("sanitizeStageConfig returns false when nothing to fix")
    func noFixNeeded() {
        let rule = Rule(
            match: MatchConfig(field: "original:IPTC:Keywords", pattern: "glob:*"),
            emit: [EmitConfig(
                action: "remove", field: "IPTC:Keywords",
                values: ["regex:.*\\d+mm.*", "Negative Lab Pro"],
                replacements: nil, source: nil
            )]
        )
        let stage = StageConfig(preRules: [rule], binary: nil, postRules: nil)

        let (_, didFix) = RegexSanitizer.sanitizeStageConfig(stage)
        #expect(!didFix)
    }

    @Test("sanitizeStageConfig fixes replacement patterns")
    func sanitizesReplacementPatterns() {
        let rule = Rule(
            match: MatchConfig(field: "IPTC:Keywords", pattern: "glob:*"),
            emit: [EmitConfig(
                action: "replace", field: "IPTC:Keywords",
                values: nil,
                replacements: [Replacement(pattern: "regex:\\\\d+mm", replacement: "fixed")],
                source: nil
            )]
        )
        let stage = StageConfig(preRules: [rule], binary: nil, postRules: nil)

        let (result, didFix) = RegexSanitizer.sanitizeStageConfig(stage)
        #expect(didFix)
        #expect(result.preRules![0].emit[0].replacements![0].pattern == "regex:\\d+mm")
    }
}
