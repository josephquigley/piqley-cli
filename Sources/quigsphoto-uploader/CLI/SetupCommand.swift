import ArgumentParser
import Foundation

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup — configure Ghost, SMTP, and processing settings"
    )

    func run() throws {
        print("Welcome to \(AppConstants.binaryName) setup!")
        print("This will walk you through configuring the tool.\n")

        // Ghost
        let ghostURL = prompt("Ghost CMS URL (e.g., https://quigs.photo):")
        let windowStart = prompt("Scheduling window start (HH:MM, default 08:00):", default: "08:00")
        let windowEnd = prompt("Scheduling window end (HH:MM, default 10:00):", default: "10:00")
        let timezone = prompt("Timezone (e.g., America/New_York):", default: "America/New_York")

        // Processing
        let maxLongEdgeStr = prompt("Max long edge pixels (default 2000):", default: "2000")
        let maxLongEdge = Int(maxLongEdgeStr) ?? 2000
        let jpegQualityStr = prompt("JPEG quality 1-100 (default 80):", default: "80")
        let jpegQuality = Int(jpegQualityStr) ?? 80

        // 365 Project
        let keyword365 = prompt("365 Project keyword (default \"365 Project\"):", default: "365 Project")
        let refDate = prompt("365 Project reference date (YYYY-MM-DD, default 2025-12-25):", default: "2025-12-25")
        let emailTo = prompt("365 Project email address:")

        // SMTP
        let smtpHost = prompt("SMTP host:")
        let smtpPortStr = prompt("SMTP port (default 587):", default: "587")
        let smtpPort = Int(smtpPortStr) ?? 587
        let smtpUsername = prompt("SMTP username:")
        let smtpFrom = prompt("SMTP from address (default: same as username):", default: smtpUsername)

        // Tag blocklist
        let blocklistStr = prompt("Tag blocklist (comma-separated, or empty; use glob: or regex: prefixes for patterns):", default: "")
        let blocklist = blocklistStr.isEmpty ? [] : blocklistStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        // Signing (optional)
        var signingConfig: AppConfig.SigningConfig? = nil
        let enableSigning = prompt("Enable image signing? (y/n):", default: "n")
        if enableSigning.lowercased() == "y" {
            print("\nAvailable GPG secret keys:")
            let listProcess = Process()
            listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            listProcess.arguments = ["gpg", "--list-secret-keys", "--keyid-format", "long"]
            listProcess.standardError = FileHandle.standardError
            do {
                try listProcess.run()
                listProcess.waitUntilExit()
            } catch {
                print("Could not list GPG keys. Is gnupg installed?")
            }

            let fingerprint = prompt("GPG key fingerprint:")
            if !fingerprint.isEmpty {
                let customNs = prompt("XMP namespace (default: \(AppConfig.SigningConfig.defaultXmpNamespace)):", default: AppConfig.SigningConfig.defaultXmpNamespace)
                let customPrefix = prompt("XMP prefix (default: \(AppConfig.SigningConfig.defaultXmpPrefix)):", default: AppConfig.SigningConfig.defaultXmpPrefix)
                signingConfig = AppConfig.SigningConfig(
                    keyFingerprint: fingerprint,
                    xmpNamespace: customNs,
                    xmpPrefix: customPrefix
                )
            }
        }

        var config = AppConfig(
            ghost: .init(
                url: ghostURL,
                schedulingWindow: .init(start: windowStart, end: windowEnd, timezone: timezone)
            ),
            processing: .init(maxLongEdge: maxLongEdge, jpegQuality: jpegQuality),
            project365: .init(keyword: keyword365, referenceDate: refDate, emailTo: emailTo),
            smtp: .init(host: smtpHost, port: smtpPort, username: smtpUsername, from: smtpFrom),
            tagBlocklist: blocklist
        )
        config.signing = signingConfig

        try config.save(to: AppConfig.configPath.path)
        print("\nConfig saved to \(AppConfig.configPath.path)")

        // Secrets
        let secretStore = KeychainSecretStore()

        let ghostAPIKey = promptSecret("Ghost Admin API key (id:secret):")
        try secretStore.set(key: "\(AppConstants.keychainServicePrefix)-ghost", value: ghostAPIKey)
        print("Ghost API key saved to Keychain.")

        let smtpPassword = promptSecret("SMTP password:")
        try secretStore.set(key: "\(AppConstants.keychainServicePrefix)-smtp", value: smtpPassword)
        print("SMTP password saved to Keychain.")

        print("\nSetup complete! Run `\(AppConstants.binaryName) process <folder>` to start processing.")
    }

    private func prompt(_ message: String, default defaultValue: String? = nil) -> String {
        if let defaultValue {
            print("\(message) [\(defaultValue)] ", terminator: "")
        } else {
            print("\(message) ", terminator: "")
        }
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.isEmpty else {
            return defaultValue ?? ""
        }
        return input
    }

    private func promptSecret(_ message: String) -> String {
        print("\(message) ", terminator: "")
        // In a real implementation, you'd disable echo here
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return input
    }
}
