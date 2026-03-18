import XCTest
@testable import piqley

final class GhostClientTests: XCTestCase {
    func testJWTGeneration() throws {
        let apiKey = "0000000000:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let jwt = try GhostClient.generateJWT(from: apiKey)
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        let headerData = Data(base64URLEncoded: String(parts[0]))!
        let header = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "HS256")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        XCTAssertEqual(header["kid"] as? String, "0000000000")
    }

    func testExtractFilenameFromGhostURL() {
        let url = "https://quigs.photo/content/images/2026/03/IMG_1234.jpg"
        XCTAssertEqual(GhostClient.extractFilename(from: url), "IMG_1234.jpg")
        let url2 = "https://example.com/images/photo.jpeg"
        XCTAssertEqual(GhostClient.extractFilename(from: url2), "photo.jpeg")
    }
}
