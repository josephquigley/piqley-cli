import Foundation

struct Rule: Codable, Sendable {
    let match: MatchConfig
    let emit: EmitConfig
}

struct MatchConfig: Codable, Sendable {
    let hook: String?
    let field: String
    let pattern: String
}

struct EmitConfig: Codable, Sendable {
    let field: String?
    let values: [String]
}
