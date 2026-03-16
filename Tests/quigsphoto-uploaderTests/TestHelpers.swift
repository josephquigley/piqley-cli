import Foundation
import CoreGraphics
import ImageIO

enum TestFixtures {
    static func createTestJPEG(
        at path: String,
        width: Int = 3000,
        height: Int = 2000,
        title: String? = nil,
        description: String? = nil,
        keywords: [String]? = nil,
        dateTimeOriginal: String? = "2026:01:15 10:30:00"
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw TestFixtureError.cannotCreateContext }

        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else { throw TestFixtureError.cannotCreateImage }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) else {
            throw TestFixtureError.cannotCreateDestination
        }

        var properties: [String: Any] = [:]
        var exifDict: [String: Any] = [:]
        var iptcDict: [String: Any] = [:]

        if let dateTimeOriginal { exifDict[kCGImagePropertyExifDateTimeOriginal as String] = dateTimeOriginal }
        if let title { iptcDict[kCGImagePropertyIPTCObjectName as String] = title }
        if let description { iptcDict[kCGImagePropertyIPTCCaptionAbstract as String] = description }
        if let keywords { iptcDict[kCGImagePropertyIPTCKeywords as String] = keywords }

        if !exifDict.isEmpty { properties[kCGImagePropertyExifDictionary as String] = exifDict }
        if !iptcDict.isEmpty { properties[kCGImagePropertyIPTCDictionary as String] = iptcDict }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestFixtureError.cannotFinalize }
    }
}

enum TestFixtureError: Error {
    case cannotCreateContext
    case cannotCreateImage
    case cannotCreateDestination
    case cannotFinalize
}
