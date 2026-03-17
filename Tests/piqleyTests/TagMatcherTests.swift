import XCTest
@testable import piqley

final class TagMatcherTests: XCTestCase {

    // MARK: - ExactMatcher

    func testExactMatcherMatchesExact() {
        let matcher = ExactMatcher(pattern: "WIP")
        XCTAssertTrue(matcher.matches("WIP"))
    }

    func testExactMatcherCaseInsensitive() {
        let matcher = ExactMatcher(pattern: "WIP")
        XCTAssertTrue(matcher.matches("wip"))
        XCTAssertTrue(matcher.matches("Wip"))
        XCTAssertTrue(matcher.matches("wIp"))
    }

    func testExactMatcherNoPartialMatch() {
        let matcher = ExactMatcher(pattern: "WIP")
        XCTAssertFalse(matcher.matches("WIP2"))
        XCTAssertFalse(matcher.matches("MyWIP"))
    }

    func testExactMatcherDescription() {
        let matcher = ExactMatcher(pattern: "Draft")
        XCTAssertEqual(matcher.description, "exact: Draft")
    }

    // MARK: - GlobMatcher

    func testGlobMatcherWildcardStar() {
        let matcher = GlobMatcher(pattern: "_*")
        XCTAssertTrue(matcher.matches("_internal"))
        XCTAssertTrue(matcher.matches("_draft"))
        XCTAssertTrue(matcher.matches("_"))
        XCTAssertFalse(matcher.matches("Nature"))
        XCTAssertFalse(matcher.matches("my_tag"))
    }

    func testGlobMatcherWildcardQuestion() {
        let matcher = GlobMatcher(pattern: "Photo?")
        XCTAssertTrue(matcher.matches("Photo1"))
        XCTAssertTrue(matcher.matches("PhotoA"))
        XCTAssertTrue(matcher.matches("Photos"))
        XCTAssertFalse(matcher.matches("Photo"))
        XCTAssertFalse(matcher.matches("Photo12"))
    }

    func testGlobMatcherCaseInsensitive() {
        let matcher = GlobMatcher(pattern: "draft*")
        XCTAssertTrue(matcher.matches("Draft"))
        XCTAssertTrue(matcher.matches("DRAFT_v2"))
        XCTAssertTrue(matcher.matches("draft"))
    }

    func testGlobMatcherDescription() {
        let matcher = GlobMatcher(pattern: "_*")
        XCTAssertEqual(matcher.description, "glob: _*")
    }

    // MARK: - RegexMatcher

    func testRegexMatcherValid() throws {
        let matcher = try RegexMatcher(pattern: "^DSC\\d+$")
        XCTAssertTrue(matcher.matches("DSC1234"))
        XCTAssertTrue(matcher.matches("DSC0"))
        XCTAssertFalse(matcher.matches("MyDSC1234"))
        XCTAssertFalse(matcher.matches("DSC"))
        XCTAssertFalse(matcher.matches("DSC123abc"))
    }

    func testRegexMatcherCaseInsensitive() throws {
        let matcher = try RegexMatcher(pattern: "^DSC\\d+$")
        XCTAssertTrue(matcher.matches("dsc1234"))
        XCTAssertTrue(matcher.matches("Dsc999"))
    }

    func testRegexMatcherInvalidThrows() {
        XCTAssertThrowsError(try RegexMatcher(pattern: "[invalid"))
    }

    func testRegexMatcherDescription() throws {
        let matcher = try RegexMatcher(pattern: "^DSC\\d+$")
        XCTAssertEqual(matcher.description, "regex: ^DSC\\d+$")
    }

    // MARK: - TagMatcherFactory

    func testBuildMatchersParsesPrefixes() throws {
        let matchers = try TagMatcherFactory.buildMatchers(from: ["WIP", "glob:_*", "regex:^DSC\\d+$"])
        XCTAssertEqual(matchers.count, 3)
        XCTAssertTrue(matchers[0] is ExactMatcher)
        XCTAssertTrue(matchers[1] is GlobMatcher)
        XCTAssertTrue(matchers[2] is RegexMatcher)
    }

    func testBuildMatchersEmptyArray() throws {
        let matchers = try TagMatcherFactory.buildMatchers(from: [])
        XCTAssertTrue(matchers.isEmpty)
    }

    func testBuildMatchersInvalidRegexThrows() {
        XCTAssertThrowsError(try TagMatcherFactory.buildMatchers(from: ["regex:[invalid"]))
    }

    // MARK: - filterKeywords Integration

    func testFilterKeywordsWithMixedMatchers() throws {
        let matchers = try TagMatcherFactory.buildMatchers(from: ["WIP", "glob:_*", "regex:^DSC\\d+$"])
        let raw = ["Location > USA > Nashville", "WIP", "_internal", "DSC1234", "Nature"]
        let result = ImageMetadata.filterKeywords(raw, blocklist: matchers)

        XCTAssertEqual(result.kept, ["Nashville", "Nature"])
        XCTAssertEqual(result.blocked.count, 3)
        XCTAssertEqual(result.blocked[0].keyword, "WIP")
        XCTAssertTrue(result.blocked[0].matcher.contains("exact"))
        XCTAssertEqual(result.blocked[1].keyword, "_internal")
        XCTAssertTrue(result.blocked[1].matcher.contains("glob"))
        XCTAssertEqual(result.blocked[2].keyword, "DSC1234")
        XCTAssertTrue(result.blocked[2].matcher.contains("regex"))
    }

    func testFilterKeywordsNothingBlocked() throws {
        let matchers = try TagMatcherFactory.buildMatchers(from: ["WIP"])
        let raw = ["Nature", "Landscape"]
        let result = ImageMetadata.filterKeywords(raw, blocklist: matchers)

        XCTAssertEqual(result.kept, ["Nature", "Landscape"])
        XCTAssertTrue(result.blocked.isEmpty)
    }

    func testFilterKeywordsCaseInsensitive() throws {
        let matchers = try TagMatcherFactory.buildMatchers(from: ["wip"])
        let raw = ["WIP", "Nature"]
        let result = ImageMetadata.filterKeywords(raw, blocklist: matchers)

        XCTAssertEqual(result.kept, ["Nature"])
        XCTAssertEqual(result.blocked.count, 1)
        XCTAssertEqual(result.blocked[0].keyword, "WIP")
    }
}
