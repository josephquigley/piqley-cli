import Foundation

struct TempFolder: Sendable {
    let url: URL

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "jxl"]

    static func create() throws -> TempFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TempFolder(url: url)
    }

    /// Copies image files (jpg, jpeg, jxl) from `sourceURL` into this temp folder.
    /// Skips hidden files (names starting with ".").
    func copyImages(from sourceURL: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix("."),
                  Self.imageExtensions.contains(file.pathExtension.lowercased())
            else { continue }
            let destination = url.appendingPathComponent(name)
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }

    func delete() throws {
        try FileManager.default.removeItem(at: url)
    }
}
