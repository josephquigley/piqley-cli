import Foundation
import Logging

struct ScannedImage {
    let path: String
    let filename: String
    let metadata: ImageMetadata
}

struct ImageScanner {
    private static let supportedExtensions: Set<String> = ["jpg", "jpeg", "jxl"]
    private let metadataReader: MetadataReader
    private let logger = Logger(label: "\(AppConstants.name).scanner")

    init(metadataReader: MetadataReader) {
        self.metadataReader = metadataReader
    }

    func scan(folder: String) throws -> [ScannedImage] {
        let url = URL(fileURLWithPath: folder)
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let imageFiles = contents.filter {
            Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        var scanned: [ScannedImage] = []
        for file in imageFiles {
            do {
                let metadata = try metadataReader.read(from: file.path)
                scanned.append(ScannedImage(path: file.path, filename: file.lastPathComponent, metadata: metadata))
            } catch {
                logger.warning("Skipping \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return scanned.sorted { lhs, rhs in
            switch (lhs.metadata.dateTimeOriginal, rhs.metadata.dateTimeOriginal) {
            case let (dateA?, dateB?): dateA < dateB
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): lhs.filename < rhs.filename
            }
        }
    }
}
