import Foundation

struct TempFolder: Sendable {
    let url: URL

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jxl", "png", "tiff", "tif", "heic", "heif", "webp",
    ]

    struct CopyResult: Sendable {
        let copiedCount: Int
        let skippedFiles: [String]
    }

    static func create() throws -> TempFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TempFolder(url: url)
    }

    /// Copies image files from `sourceURL` into this temp folder.
    /// Skips hidden files (names starting with ".").
    /// Returns a CopyResult with the count of copied files and names of skipped non-hidden files.
    func copyImages(from sourceURL: URL) throws -> CopyResult {
        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil
        )
        var copiedCount = 0
        var skippedFiles: [String] = []
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard Self.imageExtensions.contains(file.pathExtension.lowercased()) else {
                skippedFiles.append(name)
                continue
            }
            let destination = url.appendingPathComponent(name)
            try FileManager.default.copyItem(at: file, to: destination)
            copiedCount += 1
        }
        return CopyResult(copiedCount: copiedCount, skippedFiles: skippedFiles)
    }

    /// Copies processed images back to `destinationURL`, overwriting originals.
    func copyBack(to destinationURL: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix("."),
                  Self.imageExtensions.contains(file.pathExtension.lowercased())
            else { continue }
            let destination = destinationURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }

    func delete() throws {
        try FileManager.default.removeItem(at: url)
    }
}
