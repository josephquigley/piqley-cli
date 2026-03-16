import XCTest
@testable import quigsphoto_uploader

final class LexicalBuilderTests: XCTestCase {
    func testBuildWithImageAndText() throws {
        let lexical = LexicalBuilder.build(imageURL: "https://quigs.photo/content/images/photo.jpg", title: "Sunset", description: "Beautiful sunset over the ocean")
        let data = lexical.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["root"])
        XCTAssertTrue(lexical.contains("photo.jpg"))
        XCTAssertTrue(lexical.contains("Sunset"))
        XCTAssertTrue(lexical.contains("Beautiful sunset"))
    }

    func testBuildWithImageOnly() throws {
        let lexical = LexicalBuilder.build(imageURL: "https://quigs.photo/content/images/photo.jpg", title: nil, description: nil)
        let data = lexical.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["root"])
        XCTAssertTrue(lexical.contains("photo.jpg"))
    }

    func testBuildWithTitleNoDescription() throws {
        let lexical = LexicalBuilder.build(imageURL: "https://example.com/img.jpg", title: "My Photo", description: nil)
        XCTAssertTrue(lexical.contains("My Photo"))
    }
}
