import Foundation
import ImageIO

struct GPGImageSigner: ImageSigner {
    let config: AppConfig.SigningConfig

    enum SigningError: Error, CustomStringConvertible {
        case gpgNotFound
        case gpgFailed(String)
        case xmpWriteFailed(String)

        var description: String {
            switch self {
            case .gpgNotFound: return "GPG not found. Install with: brew install gnupg"
            case .gpgFailed(let msg): return "GPG signing failed: \(msg)"
            case .xmpWriteFailed(let msg): return "Failed to write XMP signature: \(msg)"
            }
        }
    }

    func sign(imageAt path: String) async throws -> SigningResult {
        guard GPGImageSigner.isGPGAvailable() else {
            throw SigningError.gpgNotFound
        }
        guard let namespace = config.xmpNamespace else {
            throw SigningError.xmpWriteFailed("XMP namespace not configured. Ensure signing config has a resolved namespace.")
        }

        // 1. Hash the file before any XMP modification
        let extractor = SignableContentExtractor()
        let contentHash = try extractor.hashFile(at: path)

        // 2. Sign the hash with GPG
        let signature = try gpgSign(data: contentHash, keyFingerprint: config.keyFingerprint)

        // 3. Embed XMP signature fields
        try writeXMPSignature(
            to: path,
            contentHash: contentHash,
            signature: signature,
            keyFingerprint: config.keyFingerprint,
            namespace: namespace,
            prefix: config.xmpPrefix
        )

        return SigningResult(
            contentHash: contentHash,
            signature: signature,
            keyFingerprint: config.keyFingerprint
        )
    }

    private func gpgSign(data: String, keyFingerprint: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--detach-sign", "--armor", "-u", keyFingerprint]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(data.utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SigningError.gpgFailed(stderr)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeXMPSignature(
        to path: String,
        contentHash: String,
        signature: String,
        keyFingerprint: String,
        namespace: String,
        prefix: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageType = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SigningError.xmpWriteFailed("Cannot read image")
        }

        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // Build XMP metadata with signing fields
        let xmpMetadata = CGImageMetadataCreateMutable()
        let fields: [(String, String)] = [
            ("contentHash", contentHash),
            ("signature", signature),
            ("keyFingerprint", keyFingerprint),
            ("algorithm", "GPG-SHA256"),
        ]
        for (name, value) in fields {
            guard let tag = CGImageMetadataTagCreate(
                namespace as CFString,
                prefix as CFString,
                name as CFString,
                .string,
                value as CFTypeRef
            ) else {
                throw SigningError.xmpWriteFailed("Cannot create XMP tag: \(name)")
            }
            CGImageMetadataSetTagWithPath(xmpMetadata, nil, "\(prefix):\(name)" as CFString, tag)
        }

        // Write image with original properties + new XMP
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, imageType, 1, nil) else {
            throw SigningError.xmpWriteFailed("Cannot create image destination")
        }

        CGImageDestinationAddImageAndMetadata(dest, cgImage, xmpMetadata, existingProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SigningError.xmpWriteFailed("Cannot finalize image")
        }
    }

    // MARK: - Static helpers

    static func isGPGAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Check if GPG can sign without interactive passphrase entry (e.g., agent has cached passphrase or key has no passphrase)
    static func canSignNonInteractively(keyFingerprint: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--detach-sign", "--armor", "-u", keyFingerprint, "--batch", "--yes", "--no-tty"]
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data("test".utf8))
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func firstAvailableKeyFingerprint() throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--list-secret-keys", "--keyid-format", "long", "--with-colons"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("fpr:") {
                let fields = line.components(separatedBy: ":")
                if fields.count > 9 {
                    return fields[9]
                }
            }
        }
        return nil
    }
}
