import Foundation
import ImageIO

struct XMPSignatureFields {
    let contentHash: String
    let signature: String
    let keyFingerprint: String
    let algorithm: String
}

enum XMPSignatureReader {
    static func read(from path: String, namespace _: String, prefix: String) throws -> XMPSignatureFields? {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else {
            return nil
        }

        let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []

        var contentHash: String?
        var signature: String?
        var keyFingerprint: String?
        var algorithm: String?

        for tag in tags {
            guard let tagPrefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  tagPrefix == prefix,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  let value = CGImageMetadataTagCopyValue(tag) as? String
            else {
                continue
            }
            switch name {
            case "contentHash": contentHash = value
            case "signature": signature = value
            case "keyFingerprint": keyFingerprint = value
            case "algorithm": algorithm = value
            default: break
            }
        }

        guard let hash = contentHash, let sig = signature, let fp = keyFingerprint, let alg = algorithm else {
            return nil
        }
        return XMPSignatureFields(contentHash: hash, signature: sig, keyFingerprint: fp, algorithm: alg)
    }
}
