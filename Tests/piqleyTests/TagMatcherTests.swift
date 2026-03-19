import Testing
import Foundation
@testable import piqley

@Suite("TagMatcher")
struct TagMatcherTests {

    @Test("ExactMatcher matches case-insensitively")
    func exactMatchCaseInsensitive() {
        let matcher = ExactMatcher(pattern: "Sony")
        #expect(matcher.matches("sony"))
        #expect(matcher.matches("SONY"))
        #expect(matcher.matches("Sony"))
    }

    @Test("ExactMatcher does not match different strings")
    func exactMatchNonMatch() {
        let matcher = ExactMatcher(pattern: "Sony")
        #expect(!matcher.matches("Canon"))
        #expect(!matcher.matches("Son"))
        #expect(!matcher.matches("Sony Alpha"))
    }

    @Test("GlobMatcher matches wildcard patterns")
    func globWildcard() {
        let matcher = GlobMatcher(pattern: "Sony*")
        #expect(matcher.matches("Sony Alpha"))
        #expect(matcher.matches("Sony"))
        #expect(!matcher.matches("Canon"))
    }

    @Test("GlobMatcher matches case-insensitively")
    func globCaseInsensitive() {
        let matcher = GlobMatcher(pattern: "sony*")
        #expect(matcher.matches("SONY Alpha"))
        #expect(matcher.matches("Sony A7R"))
    }

    @Test("RegexMatcher matches valid pattern")
    func regexMatch() throws {
        let matcher = try RegexMatcher(pattern: ".*a7r.*")
        #expect(matcher.matches("Sony A7R IV"))
    }

    @Test("RegexMatcher matches case-insensitively")
    func regexCaseInsensitive() throws {
        let matcher = try RegexMatcher(pattern: ".*a7r.*")
        #expect(matcher.matches("ILCE-A7R4"))
        #expect(matcher.matches("a7r"))
    }

    @Test("TagMatcherFactory routes regex: prefix correctly")
    func factoryRegex() throws {
        let matcher = try TagMatcherFactory.build(from: "regex:.*test.*")
        #expect(matcher is RegexMatcher)
        #expect(matcher.matches("a test string"))
    }

    @Test("TagMatcherFactory routes glob: prefix correctly")
    func factoryGlob() throws {
        let matcher = try TagMatcherFactory.build(from: "glob:test*")
        #expect(matcher is GlobMatcher)
        #expect(matcher.matches("testing"))
    }

    @Test("TagMatcherFactory routes bare string to ExactMatcher")
    func factoryExact() throws {
        let matcher = try TagMatcherFactory.build(from: "test")
        #expect(matcher is ExactMatcher)
        #expect(matcher.matches("test"))
        #expect(!matcher.matches("testing"))
    }

    @Test("TagMatcherFactory throws on invalid regex")
    func factoryInvalidRegex() {
        #expect(throws: TagMatcherError.self) {
            try TagMatcherFactory.build(from: "regex:[invalid")
        }
    }

    // MARK: - Replacing

    @Test("RegexMatcher replaces with capture groups")
    func regexReplace() throws {
        let matcher = try RegexMatcher(pattern: "SONY(.+)")
        let result = matcher.replacing("SONYA7R5", with: "Sony $1")
        #expect(result == "Sony A7R5")
    }

    @Test("RegexMatcher replace no match returns original")
    func regexReplaceNoMatch() throws {
        let matcher = try RegexMatcher(pattern: "SONY(.+)")
        let result = matcher.replacing("Canon", with: "Sony $1")
        #expect(result == "Canon")
    }

    @Test("ExactMatcher replace returns replacement on match")
    func exactReplace() {
        let matcher = ExactMatcher(pattern: "old")
        let result = matcher.replacing("Old", with: "new")
        #expect(result == "new")
    }

    @Test("ExactMatcher replace no match returns original")
    func exactReplaceNoMatch() {
        let matcher = ExactMatcher(pattern: "old")
        let result = matcher.replacing("other", with: "new")
        #expect(result == "other")
    }

    @Test("GlobMatcher replace returns replacement on match")
    func globReplace() {
        let matcher = GlobMatcher(pattern: "SONY*")
        let result = matcher.replacing("SONYA7R5", with: "Sony Camera")
        #expect(result == "Sony Camera")
    }
}
