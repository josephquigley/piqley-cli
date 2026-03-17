import Foundation
import Logging

struct GhostDeduplicator {
    private let uploadLog: UploadLog
    private let client: GhostClient?
    private let logger = Logger(label: "\(AppConstants.name).dedup")
    private let maxAge: TimeInterval = 365 * 24 * 60 * 60

    init(uploadLog: UploadLog, client: GhostClient?) {
        self.uploadLog = uploadLog
        self.client = client
    }

    func checkCacheOnly(filename: String) throws -> Bool {
        try uploadLog.contains(filename: filename)
    }

    /// Throws GhostDeduplicatorError.apiFailed on Ghost API failure (fatal per spec).
    func isDuplicate(filename: String) async throws -> Bool {
        if try uploadLog.contains(filename: filename) {
            logger.info("Dedup cache hit: \(filename)")
            return true
        }
        guard let client else { return false }

        let dateFormatter = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-maxAge)

        do {
            for status in ["published", "scheduled", "draft"] {
                var page = 1
                pageLoop: while true {
                    let response = try await client.getPosts(status: status, filter: nil, page: page)
                    for post in response.posts {
                        if let dateStr = post.publishedAt ?? post.updatedAt,
                           let date = dateFormatter.date(from: dateStr),
                           date < cutoff
                        {
                            break pageLoop
                        }
                        if let featureImage = post.featureImage,
                           let postFilename = GhostClient.extractFilename(from: featureImage),
                           postFilename == filename
                        {
                            logger.info("Dedup Ghost API hit: \(filename) (post \(post.id))")
                            let entry = UploadLogEntry(
                                filename: filename, ghostUrl: featureImage,
                                postId: post.id, timestamp: Date()
                            )
                            try? uploadLog.append(entry)
                            return true
                        }
                    }
                    guard let meta = response.meta, meta.pagination?.next != nil else { break }
                    page += 1
                }
            }
        } catch {
            throw GhostDeduplicatorError.apiFailed(underlying: error)
        }
        return false
    }
}

enum GhostDeduplicatorError: Error, LocalizedError {
    case apiFailed(underlying: Error)
    var errorDescription: String? {
        switch self {
        case let .apiFailed(err): "Ghost API dedup query failed (fatal): \(formatError(err))"
        }
    }

    var failureReason: String? {
        switch self {
        case .apiFailed: "The Ghost API did not return a valid response for the deduplication check."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .apiFailed: "Verify your Ghost API URL and admin key are correct, and that the Ghost server is reachable."
        }
    }
}
