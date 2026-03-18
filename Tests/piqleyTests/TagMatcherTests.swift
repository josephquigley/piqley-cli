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
}
