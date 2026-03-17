import Foundation

struct ImageMetadata {
    let title: String?
    let description: String?
    let keywords: [String]
    let dateTimeOriginal: Date?
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?

    static func leafKeyword(_ keyword: String) -> String {
        let parts = keyword.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.last ?? keyword
    }

    static func processKeywords(_ raw: [String], blocklist: [TagMatcher]) -> [String] {
        raw.map { leafKeyword($0) }.filter { keyword in
            !blocklist.contains { $0.matches(keyword) }
        }
    }

    static func filterKeywords(_ raw: [String], blocklist: [TagMatcher]) -> KeywordFilterResult {
        var kept: [String] = []
        var blocked: [(keyword: String, matcher: String)] = []
        for keyword in raw.map({ leafKeyword($0) }) {
            if let matcher = blocklist.first(where: { $0.matches(keyword) }) {
                blocked.append((keyword: keyword, matcher: matcher.description))
            } else {
                kept.append(keyword)
            }
        }
        return KeywordFilterResult(kept: kept, blocked: blocked)
    }

    func matchingCameraTags(from _: [String: [String]], matchers: [(TagMatcher, [String])]) -> [String] {
        guard let model = cameraModel else { return [] }
        var result: [String] = []
        for (matcher, tags) in matchers {
            if matcher.matches(model) {
                result.append(contentsOf: tags)
            }
        }
        return result
    }

    func is365Project(keyword: String) -> Bool {
        let leaves = keywords.map { ImageMetadata.leafKeyword($0) }
        return leaves.contains(keyword)
    }
}
