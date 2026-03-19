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

            let properties = buildProperties(from: metadata)

            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp")

            guard let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL, uti, CGImageSourceGetCount(source), nil
            ) else {
                throw MetadataWriteError.destinationCreationFailed
            }

            for index in 0 ..< CGImageSourceGetCount(source) {
                CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
            }

            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw MetadataWriteError.finalizeFailed
            }

            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
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
