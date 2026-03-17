import ArgumentParser
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify the cryptographic signature of a signed image"
    )

    @Argument(help: "Path to JPEG image to verify")
    var imagePath: String

    @Option(help: "Assert the signature was made by this specific GPG key fingerprint")
    var keyFingerprint: String?

    func run() throws {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw ValidationError("File not found: \(imagePath)")
        }

        // Load config for XMP namespace settings (use defaults if no config)
        let signingConfig: AppConfig.SigningConfig
        if FileManager.default.fileExists(atPath: AppConfig.configPath.path),
           let config = try? AppConfig.load(from: AppConfig.configPath.path),
           let signing = config.signing {
            signingConfig = signing
        } else {
            signingConfig = AppConfig.SigningConfig(keyFingerprint: "")
        }

        // Read XMP signature
        guard let xmp = try XMPSignatureReader.read(
            from: imagePath,
            namespace: signingConfig.xmpNamespace,
            prefix: signingConfig.xmpPrefix
        ) else {
            print("No signature found in image.")
            throw ExitCode(1)
        }

        // Recompute content hash by stripping signing XMP and hashing
        let extractor = SignableContentExtractor()
        let computedHash = try extractor.hashFileStrippingSignature(
            at: imagePath,
            namespace: signingConfig.xmpNamespace,
            prefix: signingConfig.xmpPrefix
        )

        // Check integrity
        let integrityPass = computedHash == xmp.contentHash
        print("Signed by: \(xmp.keyFingerprint)")
        print("Algorithm: \(xmp.algorithm)")
        print("Content integrity: \(integrityPass ? "PASS" : "FAIL")")

        if !integrityPass {
            print("WARNING: Image content has been modified since signing!")
            throw ExitCode(1)
        }

        // Verify GPG signature
        guard GPGImageSigner.isGPGAvailable() else {
            print("Signature validity: CANNOT VERIFY (GPG not installed)")
            throw ExitCode(1)
        }

        let signatureValid = try verifyGPGSignature(
            signature: xmp.signature,
            data: xmp.contentHash,
            expectedFingerprint: keyFingerprint
        )

        if signatureValid {
            print("Signature validity: VALID")
        } else {
            print("Signature validity: INVALID")
            throw ExitCode(1)
        }
    }

    private func verifyGPGSignature(signature: String, data: String, expectedFingerprint: String?) throws -> Bool {
        let tmpDir = FileManager.default.temporaryDirectory
        let sigFile = tmpDir.appendingPathComponent("quigsphoto-verify-\(UUID().uuidString).sig")
        let dataFile = tmpDir.appendingPathComponent("quigsphoto-verify-\(UUID().uuidString).dat")
        defer {
            try? FileManager.default.removeItem(at: sigFile)
            try? FileManager.default.removeItem(at: dataFile)
        }

        try Data(signature.utf8).write(to: sigFile)
        try Data(data.utf8).write(to: dataFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gpg", "--verify", sigFile.path, dataFile.path]

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            if stderr.contains("No public key") {
                print("Signature validity: UNKNOWN KEY")
            }
            return false
        }

        // If a specific fingerprint is required, check it
        if let expected = expectedFingerprint {
            return stderr.contains(expected)
        }

        return true
    }
}
