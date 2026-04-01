import Foundation
import PiqleyCore

struct TempFolder: Sendable {
    let url: URL
    let fileManager: any FileSystemManager

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jxl", "png", "tiff", "tif", "heic", "heif", "webp",
    ]

    struct CopyResult: Sendable {
        let copiedCount: Int
        let skippedFiles: [String]
    }

    static func create(fileManager: any FileSystemManager = FileManager.default) throws -> TempFolder {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("piqley-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return TempFolder(url: url, fileManager: fileManager)
    }

    /// Copies image files from `sourceURL` into this temp folder.
    /// Skips hidden files (names starting with ".").
    /// Returns a CopyResult with the count of copied files and names of skipped non-hidden files.
    func copyImages(from sourceURL: URL) throws -> CopyResult {
        let contents = try fileManager.contentsOfDirectory(
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
            try fileManager.copyItem(at: file, to: destination)
            copiedCount += 1
        }
        return CopyResult(copiedCount: copiedCount, skippedFiles: skippedFiles)
    }

    /// Copies processed images back to `destinationURL`, overwriting originals.
    func copyBack(to destinationURL: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        for file in contents {
            let name = file.lastPathComponent
            guard !name.hasPrefix("."),
                  Self.imageExtensions.contains(file.pathExtension.lowercased())
            else { continue }
            let destination = destinationURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: file, to: destination)
        }
    }

    func delete() throws {
        try fileManager.removeItem(at: url)
    }
}
