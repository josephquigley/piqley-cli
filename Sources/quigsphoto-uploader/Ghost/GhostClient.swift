import Foundation
import Logging
import CommonCrypto

final class GhostClient {
    let baseURL: String
    private let apiKey: String
    private let session: URLSession
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).ghost")

    init(baseURL: String, apiKey: String, timeoutInterval: TimeInterval = 30) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutInterval
        self.session = URLSession(configuration: config)
    }

    static func generateJWT(from apiKey: String) throws -> String {
        let parts = apiKey.split(separator: ":")
        guard parts.count == 2 else { throw GhostClientError.invalidAPIKey }
        let keyId = String(parts[0])
        let secretHex = String(parts[1])
        guard let secretData = Data(hexEncoded: secretHex) else { throw GhostClientError.invalidAPIKey }

        let header = #"{"alg":"HS256","typ":"JWT","kid":"\#(keyId)"}"#
        let now = Int(Date().timeIntervalSince1970)
        let payload = #"{"iat":\#(now),"exp":\#(now + 300),"aud":"/admin/"}"#

        let headerB64 = Data(header.utf8).base64URLEncodedString()
        let payloadB64 = Data(payload.utf8).base64URLEncodedString()
        let signingInput = "\(headerB64).\(payloadB64)"
        let signature = hmacSHA256(data: Data(signingInput.utf8), key: secretData)
        return "\(headerB64).\(payloadB64).\(signature.base64URLEncodedString())"
    }

    private static func hmacSHA256(data: Data, key: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count, dataBytes.baseAddress, data.count, &hmac)
            }
        }
        return Data(hmac)
    }

    func getPosts(status: String, filter: String? = nil, page: Int = 1, limit: Int = 50) async throws -> GhostPostsResponse {
        var urlComponents = URLComponents(string: "\(baseURL)/ghost/api/admin/posts/")!
        var queryItems = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "order", value: "published_at desc"),
            URLQueryItem(name: "include", value: "tags"),
        ]
        if let filter { queryItems.append(URLQueryItem(name: "filter", value: filter)) }
        urlComponents.queryItems = queryItems
        let data = try await authenticatedRequest(url: urlComponents.url!)
        return try JSONDecoder().decode(GhostPostsResponse.self, from: data)
    }

    func uploadImage(filePath: String, filename: String) async throws -> String {
        let url = URL(string: "\(baseURL)/ghost/api/admin/images/upload/")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let jwt = try Self.generateJWT(from: apiKey)
        request.setValue("Ghost \(jwt)", forHTTPHeaderField: "Authorization")

        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        let decoded = try JSONDecoder().decode(GhostImageUploadResponse.self, from: data)
        guard let imageURL = decoded.images.first?.url else { throw GhostClientError.noImageURL }
        return imageURL
    }

    func createPost(_ post: GhostPostCreate) async throws -> GhostPost {
        let url = URL(string: "\(baseURL)/ghost/api/admin/posts/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = try Self.generateJWT(from: apiKey)
        request.setValue("Ghost \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(GhostPostCreateRequest(posts: [post]))
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        let decoded = try JSONDecoder().decode(GhostPostCreateResponse.self, from: data)
        guard let createdPost = decoded.posts.first else { throw GhostClientError.noPostReturned }
        return createdPost
    }

    static func extractFilename(from url: String) -> String? {
        URL(string: url)?.lastPathComponent
    }

    private func authenticatedRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        let jwt = try Self.generateJWT(from: apiKey)
        request.setValue("Ghost \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw GhostClientError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else { throw GhostClientError.httpError(statusCode: httpResponse.statusCode) }
    }
}

// MARK: - Error

enum GhostClientError: Error, LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case httpError(statusCode: Int)
    case noImageURL
    case noPostReturned

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid Ghost Admin API key format (expected id:secret)"
        case .invalidResponse: return "Invalid HTTP response"
        case .httpError(let code): return "Ghost API error: HTTP \(code)"
        case .noImageURL: return "No image URL in upload response"
        case .noPostReturned: return "No post returned from create"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    init?(hexEncoded hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex
        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
