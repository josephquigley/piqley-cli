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

    static func processKeywords(_ raw: [String], blocklist: [String]) -> [String] {
        raw.map { leafKeyword($0) }.filter { !blocklist.contains($0) }
    }

    func is365Project(keyword: String) -> Bool {
        let leaves = keywords.map { ImageMetadata.leafKeyword($0) }
        return leaves.contains(keyword)
    }
}
