import XCTest
@testable import quigsphoto_uploader

final class LexicalBuilderTests: XCTestCase {
    func testBuildWithTitleAndDescription() throws {
        let lexical = LexicalBuilder.build(title: "Sunset", description: "Beautiful sunset over the ocean")
        let data = lexical.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["root"])
        XCTAssertTrue(lexical.contains("Sunset"))
        XCTAssertTrue(lexical.contains("Beautiful sunset"))
    }

    func testBuildWithNoContent() throws {
        let lexical = LexicalBuilder.build(title: nil, description: nil)
        let data = lexical.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["root"])
        XCTAssertFalse(lexical.contains("image"))
    }

    func testBuildWithTitleNoDescription() throws {
        let lexical = LexicalBuilder.build(title: "My Photo", description: nil)
        XCTAssertTrue(lexical.contains("My Photo"))
    }
}
