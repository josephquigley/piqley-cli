import Foundation
import CoreGraphics
import ImageIO

struct CGImageMetadataReader: MetadataReader {
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func read(from path: String) throws -> ImageMetadata {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else {
            throw MetadataReaderError.cannotOpenFile(path: path)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw MetadataReaderError.cannotReadProperties(path: path)
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

        let title = iptc[kCGImagePropertyIPTCObjectName as String] as? String
        let description = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String
        let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []

        var dateTimeOriginal: Date?
        if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            dateTimeOriginal = Self.exifDateFormatter.date(from: dateStr)
        }

        let cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
        let cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
        let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String

        return ImageMetadata(
            title: title, description: description, keywords: keywords,
            dateTimeOriginal: dateTimeOriginal, cameraMake: cameraMake,
            cameraModel: cameraModel, lensModel: lensModel
        )
    }
}

enum MetadataReaderError: Error, LocalizedError {
    case cannotOpenFile(path: String)
    case cannotReadProperties(path: String)
    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Cannot open image file: \(path)"
        case .cannotReadProperties(let path): return "Cannot read EXIF/IPTC from: \(path)"
        }
    }
}
