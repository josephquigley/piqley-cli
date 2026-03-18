import Foundation

struct SigningResult {
    let contentHash: String
    let signature: String
    let keyFingerprint: String
}

protocol ImageSigner {
    func sign(imageAt path: String) async throws -> SigningResult
}
