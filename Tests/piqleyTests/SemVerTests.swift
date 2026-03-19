import Testing
@testable import piqley

@Suite("SemVer")
struct SemVerTests {
    @Test("parses basic version")
    func testBasicParse() throws {
        let v = try SemVer.parse("1.2.3")
        #expect(v.major == 1)
        #expect(v.minor == 2)
        #expect(v.patch == 3)
    }

    @Test("parses version with v prefix")
    func testVPrefix() throws {
        let v = try SemVer.parse("v0.1.0")
        #expect(v.major == 0)
        #expect(v.minor == 1)
        #expect(v.patch == 0)
    }

    @Test("rejects non-semver string")
    func testRejectsInvalid() {
        #expect(throws: (any Error).self) {
            try SemVer.parse("not-a-version")
        }
    }

    @Test("comparable sorts correctly")
    func testComparable() throws {
        let a = try SemVer.parse("0.1.0")
        let b = try SemVer.parse("0.2.0")
        let c = try SemVer.parse("0.1.5")
        #expect(a < c)
        #expect(c < b)
    }

    @Test("versionString strips v prefix")
    func testVersionString() throws {
        let v = try SemVer.parse("v1.2.3")
        #expect(v.versionString == "1.2.3")
    }

    @Test("isCompatible matches major for >= 1.0")
    func testCompatibleMajor() throws {
        let cli = try SemVer.parse("2.3.0")
        let tag = try SemVer.parse("2.1.0")
        let other = try SemVer.parse("1.9.0")
        #expect(cli.isCompatible(with: tag) == true)
        #expect(cli.isCompatible(with: other) == false)
    }

    @Test("isCompatible matches major+minor for 0.x")
    func testCompatibleMinor() throws {
        let cli = try SemVer.parse("0.1.0")
        let tag = try SemVer.parse("0.1.5")
        let other = try SemVer.parse("0.2.0")
        #expect(cli.isCompatible(with: tag) == true)
        #expect(cli.isCompatible(with: other) == false)
    }
}
