import Foundation

// MARK: - Ghost Post

struct GhostPost: Codable {
    let id: String
    let uuid: String?
    let title: String?
    let slug: String?
    let html: String?
    let featureImage: String?
    let featured: Bool?
    let status: String?
    let visibility: String?
    let publishedAt: String?
    let createdAt: String?
    let updatedAt: String?
    let tags: [GhostTag]?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, slug, html
        case featureImage = "feature_image"
        case featured, status, visibility
        case publishedAt = "published_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case tags, url
    }
}

// MARK: - Ghost Tag

struct GhostTag: Codable {
    let id: String?
    let name: String?
    let slug: String?
}

// MARK: - Ghost Posts Response

struct GhostPostsResponse: Codable {
    let posts: [GhostPost]
    let meta: GhostMeta?
}

// MARK: - Ghost Meta

struct GhostMeta: Codable {
    let pagination: GhostPagination?
}

// MARK: - Ghost Pagination

struct GhostPagination: Codable {
    let page: Int?
    let limit: Int?
    let pages: Int?
    let total: Int?
    let next: Int?
    let prev: Int?
}

// MARK: - Ghost Image Upload Response

struct GhostImageUploadResponse: Codable {
    let images: [GhostImage]
}

struct GhostImage: Codable {
    let url: String
    let ref: String?
}

// MARK: - Ghost Post Create Request

struct GhostPostCreateRequest: Codable {
    let posts: [GhostPostCreate]
}

struct GhostPostCreate: Codable {
    let title: String
    let slug: String?
    let lexical: String?
    let status: String
    let publishedAt: String?
    let featureImage: String?
    let tags: [GhostTagInput]

    enum CodingKeys: String, CodingKey {
        case title, slug, lexical, status, tags
        case publishedAt = "published_at"
        case featureImage = "feature_image"
    }
}

struct GhostTagInput: Codable {
    let name: String
}

// MARK: - Ghost Post Create Response

struct GhostPostCreateResponse: Codable {
    let posts: [GhostPost]
}
