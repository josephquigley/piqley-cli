#if canImport(ImageIO)
    @preconcurrency import Foundation
    import ImageIO
    import PiqleyCore
    import UniformTypeIdentifiers

    enum MetadataWriteError: Error, LocalizedError {
        case sourceCreationFailed
        case destinationCreationFailed
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .sourceCreationFailed: "Failed to create image source"
            case .destinationCreationFailed: "Failed to create image destination"
            case .finalizeFailed: "Failed to finalize image write"
            }
        }
    }

    enum MetadataWriter {
        /// Known group prefixes mapped to CGImageSource property dictionary keys.
        private static let groupMappings: [(prefix: String, key: CFString)] = [
            ("EXIF", kCGImagePropertyExifDictionary),
            ("ExifAux", kCGImagePropertyExifAuxDictionary),
            ("IPTC", kCGImagePropertyIPTCDictionary),
            ("TIFF", kCGImagePropertyTIFFDictionary),
            ("GPS", kCGImagePropertyGPSDictionary),
            ("JFIF", kCGImagePropertyJFIFDictionary),
        ]

        /// Write metadata to an image file. Copies image data as-is, only modifies metadata.
        static func write(metadata: [String: JSONValue], to url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw MetadataWriteError.sourceCreationFailed
            }

            guard let uti = CGImageSourceGetType(source) else {
                throw MetadataWriteError.sourceCreationFailed
            }

            let desired = buildProperties(from: metadata)

            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp")

            // Pass 1: Copy image data as-is but strip all metadata groups with kCFNull.
            var stripProperties: [String: Any] = [:]
            for (_, dictKey) in groupMappings {
                stripProperties[dictKey as String] = kCFNull
            }

            guard let dest1 = CGImageDestinationCreateWithURL(
                tempURL as CFURL, uti, CGImageSourceGetCount(source), nil
            ) else {
                throw MetadataWriteError.destinationCreationFailed
            }

            for index in 0 ..< CGImageSourceGetCount(source) {
                CGImageDestinationAddImageFromSource(dest1, source, index, stripProperties as CFDictionary)
            }

            guard CGImageDestinationFinalize(dest1) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw MetadataWriteError.finalizeFailed
            }

            // Strip XMP APP1 segments — ImageIO copies them through as raw bytes.
            try stripXMPSegments(at: tempURL)

            // Pass 2: Re-open the stripped file and apply only the desired metadata.
            if !desired.isEmpty {
                guard let strippedSource = CGImageSourceCreateWithURL(tempURL as CFURL, nil) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw MetadataWriteError.sourceCreationFailed
                }

                let tempURL2 = url.deletingLastPathComponent()
                    .appendingPathComponent("..\(url.lastPathComponent).tmp")

                guard let dest2 = CGImageDestinationCreateWithURL(
                    tempURL2 as CFURL, uti, CGImageSourceGetCount(strippedSource), nil
                ) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw MetadataWriteError.destinationCreationFailed
                }

                for index in 0 ..< CGImageSourceGetCount(strippedSource) {
                    CGImageDestinationAddImageFromSource(dest2, strippedSource, index, desired as CFDictionary)
                }

                guard CGImageDestinationFinalize(dest2) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    try? FileManager.default.removeItem(at: tempURL2)
                    throw MetadataWriteError.finalizeFailed
                }

                try? FileManager.default.removeItem(at: tempURL)
                try stripXMPSegments(at: tempURL2)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL2)
            } else {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            }
        }

        /// Strip XMP APP1 segments from a JPEG file in place.
        /// XMP is stored in APP1 (FF E1) segments with the "http://ns.adobe.com/xap/1.0/\0" header.
        /// ImageIO copies these through as raw bytes, so we strip them at the byte level.
        private static func stripXMPSegments(at url: URL) throws {
            var data = try Data(contentsOf: url)
            let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
            var offset = 2 // skip SOI (FF D8)

            while offset + 4 < data.count {
                guard data[offset] == 0xFF else { break }
                let marker = data[offset + 1]

                // Stop at SOS (FF DA) — rest is image data
                if marker == 0xDA { break }

                let segmentLength = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                let segmentEnd = offset + 2 + segmentLength

                // APP1 = FF E1; check if it contains the XMP header
                if marker == 0xE1, segmentEnd <= data.count {
                    let payloadStart = offset + 4
                    let headerEnd = payloadStart + xmpHeader.count
                    if headerEnd <= data.count, data[payloadStart ..< headerEnd] == xmpHeader {
                        data.removeSubrange(offset ..< segmentEnd)
                        continue // don't advance offset — next segment is now at same position
                    }
                }

                offset = segmentEnd
            }

            try data.write(to: url)
        }

        /// Convert flat "Group:Key" metadata to nested CGImageProperties format.
        private static func buildProperties(from metadata: [String: JSONValue]) -> [String: Any] {
            var properties: [String: Any] = [:]

            for (prefix, dictKey) in groupMappings {
                var groupDict: [String: Any] = [:]
                let groupPrefix = "\(prefix):"

                for (key, value) in metadata where key.hasPrefix(groupPrefix) {
                    let tag = String(key.dropFirst(groupPrefix.count))
                    groupDict[tag] = jsonValueToAny(value)
                }

                if !groupDict.isEmpty {
                    properties[dictKey as String] = groupDict
                }
            }

            return properties
        }

        /// Convert JSONValue back to Foundation types for CGImageDestination.
        private static func jsonValueToAny(_ value: JSONValue) -> Any {
            switch value {
            case let .string(str): str
            case let .number(num): NSNumber(value: num)
            case let .bool(val): NSNumber(value: val)
            case let .array(arr): arr.map { jsonValueToAny($0) }
            case let .object(dict): dict.mapValues { jsonValueToAny($0) }
            case .null: NSNull()
            }
        }
    }
#else
    import Foundation
    import Logging
    import PiqleyCore

    enum MetadataWriteError: Error, LocalizedError {
        case sourceCreationFailed
        case destinationCreationFailed
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .sourceCreationFailed: "Failed to create image source"
            case .destinationCreationFailed: "Failed to create image destination"
            case .finalizeFailed: "Failed to finalize image write"
            }
        }
    }

    enum MetadataWriter {
        private static let logger = Logger(label: "piqley.metadata-writer")

        static func write(metadata _: [String: JSONValue], to _: URL) throws {
            logger.warning("Metadata writing is not available on this platform")
        }
    }
#endif
