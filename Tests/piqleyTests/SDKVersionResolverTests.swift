import Foundation
import Testing
@testable import piqley

@Suite("SDKVersionResolver")
struct SDKVersionResolverTests {
    @Test("parses tags from git ls-remote output")
    func testParseTags() throws {
        let output = """
        abc123\trefs/tags/v0.1.0
        def456\trefs/tags/v0.1.1
        ghi789\trefs/tags/v0.2.0
        jkl012\trefs/tags/not-semver
        mno345\trefs/tags/v0.1.0^{}
        """
        let tags = SDKVersionResolver.parseTags(from: output)
        #expect(tags.count == 3)
        #expect(tags[0].versionString == "0.1.0")
        #expect(tags[1].versionString == "0.1.1")
        #expect(tags[2].versionString == "0.2.0")
    }

    @Test("selects highest compatible tag for 0.x")
    func testSelectsHighestCompatible() throws {
        let cli = try SemVer.parse("0.1.0")
        let tags = [
            try SemVer.parse("0.1.0"),
            try SemVer.parse("0.1.5"),
            try SemVer.parse("0.2.0"),
        ]
        let result = SDKVersionResolver.bestMatch(for: cli, from: tags)
        #expect(result?.versionString == "0.1.5")
    }

    @Test("returns nil when no compatible tag exists")
    func testNoMatch() throws {
        let cli = try SemVer.parse("0.3.0")
        let tags = [
            try SemVer.parse("0.1.0"),
            try SemVer.parse("0.2.0"),
        ]
        let result = SDKVersionResolver.bestMatch(for: cli, from: tags)
        #expect(result == nil)
    }

    @Test("selects highest compatible tag for >= 1.x")
    func testMajorVersionMatch() throws {
        let cli = try SemVer.parse("2.0.0")
        let tags = [
            try SemVer.parse("1.5.0"),
            try SemVer.parse("2.0.0"),
            try SemVer.parse("2.3.1"),
            try SemVer.parse("3.0.0"),
        ]
        let result = SDKVersionResolver.bestMatch(for: cli, from: tags)
        #expect(result?.versionString == "2.3.1")
    }

    @Test("ignores peeled tag refs")
    func testIgnoresPeeled() throws {
        let output = """
        abc123\trefs/tags/v0.1.0
        def456\trefs/tags/v0.1.0^{}
        """
        let tags = SDKVersionResolver.parseTags(from: output)
        #expect(tags.count == 1)
    }
}
