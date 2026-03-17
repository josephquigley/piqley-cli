import CoreGraphics
import Foundation
import ImageIO

struct CoreGraphicsImageProcessor: ImageProcessor {
    private static let dictionaryKeys: [String: String] = [
        "EXIF": kCGImagePropertyExifDictionary as String,
        "TIFF": kCGImagePropertyTIFFDictionary as String,
        "IPTC": kCGImagePropertyIPTCDictionary as String,
    ]

    func process(
        inputPath: String, outputPath: String,
        maxLongEdge: Int, jpegQuality: Int, metadataAllowlist: [String]
    ) throws {
        let inputURL = URL(fileURLWithPath: inputPath) as CFURL
        guard let source = CGImageSourceCreateWithURL(inputURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageProcessorError.cannotReadImage(path: inputPath)
        }
        let originalProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let origWidth = cgImage.width
        let origHeight = cgImage.height
        let longEdge = max(origWidth, origHeight)
        let scale: CGFloat = longEdge <= maxLongEdge ? 1.0 : CGFloat(maxLongEdge) / CGFloat(longEdge)
        let newWidth = Int(CGFloat(origWidth) * scale)
        let newHeight = Int(CGFloat(origHeight) * scale)

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: newWidth, height: newHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            throw ImageProcessorError.cannotCreateContext
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let resizedImage = context.makeImage() else {
            throw ImageProcessorError.cannotCreateResizedImage
        }

        // Opt-in metadata: only copy explicitly allowed tags
        var outputExif: [String: Any] = [:]
        var outputTiff: [String: Any] = [:]
        var outputIptc: [String: Any] = [:]

        for entry in metadataAllowlist {
            let parts = entry.split(separator: ".", maxSplits: 1)
            guard parts.count == 2,
                  let dictKey = Self.dictionaryKeys[String(parts[0])],
                  let sourceDict = originalProps[dictKey] as? [String: Any],
                  let value = sourceDict[String(parts[1])] else { continue }

            switch String(parts[0]) {
            case "EXIF": outputExif[String(parts[1])] = value
            case "TIFF": outputTiff[String(parts[1])] = value
            case "IPTC": outputIptc[String(parts[1])] = value
            default: break
            }
        }

        var outputProps: [String: Any] = [:]
        if !outputExif.isEmpty { outputProps[kCGImagePropertyExifDictionary as String] = outputExif }
        if !outputTiff.isEmpty { outputProps[kCGImagePropertyTIFFDictionary as String] = outputTiff }
        if !outputIptc.isEmpty { outputProps[kCGImagePropertyIPTCDictionary as String] = outputIptc }
        outputProps[kCGImageDestinationLossyCompressionQuality as String] = CGFloat(jpegQuality) / 100.0

        let outputURL = URL(fileURLWithPath: outputPath) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(outputURL, "public.jpeg" as CFString, 1, nil) else {
            throw ImageProcessorError.cannotCreateDestination
        }
        CGImageDestinationAddImage(dest, resizedImage, outputProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageProcessorError.cannotWriteImage(path: outputPath)
        }
    }
}

enum ImageProcessorError: Error, LocalizedError {
    case cannotReadImage(path: String)
    case cannotCreateContext
    case cannotCreateResizedImage
    case cannotCreateDestination
    case cannotWriteImage(path: String)

    var errorDescription: String? {
        switch self {
        case let .cannotReadImage(path): "Cannot read image: \(path)"
        case .cannotCreateContext: "Cannot create graphics context"
        case .cannotCreateResizedImage: "Cannot create resized image"
        case .cannotCreateDestination: "Cannot create image destination"
        case let .cannotWriteImage(path): "Cannot write image: \(path)"
        }
    }

    var failureReason: String? {
        switch self {
        case .cannotReadImage: "The image file could not be opened or decoded."
        case .cannotCreateContext: "Core Graphics failed to allocate a bitmap context."
        case .cannotCreateResizedImage: "The resized image could not be rendered from the graphics context."
        case .cannotCreateDestination: "Core Graphics could not create an output destination."
        case .cannotWriteImage: "The processed image could not be written to disk."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cannotReadImage: "Verify the file exists and is a supported format (JPEG, PNG, HEIC)."
        case .cannotCreateContext, .cannotCreateResizedImage, .cannotCreateDestination:
            "This may indicate insufficient memory. Try processing fewer images at once."
        case .cannotWriteImage: "Check that the output directory exists and is writable."
        }
    }
}
