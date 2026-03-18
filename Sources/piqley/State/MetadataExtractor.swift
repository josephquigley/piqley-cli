#if canImport(ImageIO)
    @preconcurrency import Foundation
    import ImageIO
    import PiqleyCore

    enum MetadataExtractor {
        /// Known CGImageSource property dictionary keys mapped to short group names.
        private static let groupMappings: [(key: CFString, prefix: String)] = [
            (kCGImagePropertyExifDictionary, "EXIF"),
            (kCGImagePropertyIPTCDictionary, "IPTC"),
            (kCGImagePropertyTIFFDictionary, "TIFF"),
            (kCGImagePropertyGPSDictionary, "GPS"),
            (kCGImagePropertyJFIFDictionary, "JFIF"),
        ]

        /// Extract EXIF/IPTC/XMP metadata from an image file, returning flattened Group:Tag keys.
        static func extract(from url: URL) -> [String: JSONValue] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }

            var result: [String: JSONValue] = [:]

            for (dictKey, prefix) in groupMappings {
                guard let groupDict = properties[dictKey as String] as? [String: Any] else { continue }
                for (tag, value) in groupDict {
                    let key = "\(prefix):\(tag)"
                    result[key] = anyToJSONValue(value)
                }
            }

            return result
        }

        /// Convert a Foundation value to JSONValue.
        private static func anyToJSONValue(_ value: Any) -> JSONValue {
            switch value {
            case let string as String:
                return .string(string)
            case let number as NSNumber:
                // NSNumber wraps bools too; check CFBooleanGetTypeID
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return .bool(number.boolValue)
                }
                return .number(number.doubleValue)
            case let array as [Any]:
                return .array(array.map { anyToJSONValue($0) })
            case let dict as [String: Any]:
                return .object(dict.mapValues { anyToJSONValue($0) })
            default:
                return .string(String(describing: value))
            }
        }
    }
#else
    import Foundation
    import PiqleyCore

    enum MetadataExtractor {
        /// Metadata extraction is not available on this platform (requires ImageIO).
        /// Returns an empty dictionary.
        static func extract(from _: URL) -> [String: JSONValue] {
            [:]
        }
    }
#endif
