import CryptoKit
import Foundation
import ImageIO

struct SignableContentExtractor {
    enum ExtractionError: Error, LocalizedError {
        case cannotReadFile(String)
        case cannotProcessImage(String)

        var errorDescription: String? {
            switch self {
            case let .cannotReadFile(path): "Cannot read file at \(path)"
            case let .cannotProcessImage(path): "Cannot process image at \(path)"
            }
        }

        var failureReason: String? {
            switch self {
            case .cannotReadFile: "The file could not be opened or does not exist."
            case .cannotProcessImage: "The image data could not be decoded or written."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .cannotReadFile: "Verify the file path exists and is a supported image format."
            case .cannotProcessImage: "Ensure the image is not corrupted and is a supported format (JPEG, PNG, HEIC)."
            }
        }
    }

    /// SHA-256 hash of the raw file bytes. Used during signing (before XMP injection).
    func hashFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Strip XMP signing fields from the image, write to a temp file, and hash that.
    /// Used during verification to reconstruct the pre-signing file hash.
    func hashFileStrippingSignature(at path: String, namespace _: String, prefix: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageType = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ExtractionError.cannotReadFile(path)
        }

        // Copy all existing properties
        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // Read existing metadata and filter out signing namespace tags
        let existingMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let filteredMetadata = CGImageMetadataCreateMutable()

        if let existingMetadata {
            let allTags = CGImageMetadataCopyTags(existingMetadata) as? [CGImageMetadataTag] ?? []
            for tag in allTags {
                guard let tagPrefix = CGImageMetadataTagCopyPrefix(tag) as String? else { continue }
                // Skip tags in the signing namespace
                if tagPrefix == prefix { continue }
                guard let tagName = CGImageMetadataTagCopyName(tag) as String? else { continue }
                CGImageMetadataSetTagWithPath(filteredMetadata, nil, "\(tagPrefix):\(tagName)" as CFString, tag)
            }
        }

        // Write to temp file without signing XMP
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-verify-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        guard let dest = CGImageDestinationCreateWithURL(tmpPath as CFURL, imageType, 1, nil) else {
            throw ExtractionError.cannotProcessImage(path)
        }

        CGImageDestinationAddImageAndMetadata(dest, cgImage, filteredMetadata, existingProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExtractionError.cannotProcessImage(path)
        }

        // Hash the stripped file
        return try hashFile(at: tmpPath.path)
    }
}
