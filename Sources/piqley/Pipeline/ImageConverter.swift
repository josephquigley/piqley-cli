import CoreGraphics
import Foundation
import ImageIO

enum ImageConverter {
    static func convert(from source: URL, to destination: URL, format: String) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw ConversionError.cannotReadSource(source.lastPathComponent)
        }

        let uti = utiForFormat(format)
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, uti as CFString, 1, nil
        ) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }

        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.finalizeFailed(destination.lastPathComponent)
        }
    }

    private static func utiForFormat(_ format: String) -> String {
        switch format.lowercased() {
        case "jpg", "jpeg": "public.jpeg"
        case "png": "public.png"
        case "tiff", "tif": "public.tiff"
        case "heic", "heif": "public.heic"
        case "webp": "public.webp"
        default: "public.jpeg"
        }
    }

    enum ConversionError: Error, LocalizedError {
        case cannotReadSource(String)
        case cannotCreateDestination(String)
        case finalizeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .cannotReadSource(file): "Cannot read image: \(file)"
            case let .cannotCreateDestination(file): "Cannot create destination: \(file)"
            case let .finalizeFailed(file): "Image conversion failed: \(file)"
            }
        }
    }
}
