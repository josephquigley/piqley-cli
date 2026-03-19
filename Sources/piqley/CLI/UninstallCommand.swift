import ArgumentParser
import Foundation

#if os(macOS)
    import Security
#endif

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove all piqley configs, plugins, and stored secrets"
    )

    @Flag(help: "Skip confirmation prompt")
    var force = false

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDir = home.appendingPathComponent(".config/piqley")

        if !force {
            print("This will permanently delete:")
            print("  \(configDir.path)")
            #if os(macOS)
                print("  All Keychain items for service '\(AppConstants.name)'")
            #endif
            print("\nContinue? [y/N]: ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                print("Cancelled.")
                throw ExitCode.success
            }
        }

        // Remove config directory
        if FileManager.default.fileExists(atPath: configDir.path) {
            try FileManager.default.removeItem(at: configDir)
            print("Removed \(configDir.path)")
        } else {
            print("No config directory found at \(configDir.path)")
        }

        // Remove keychain secrets
        #if os(macOS)
            let deleted = try deleteKeychainItems(service: AppConstants.name)
            if deleted > 0 {
                print("Removed \(deleted) Keychain item(s) for service '\(AppConstants.name)'")
            } else {
                print("No Keychain items found for service '\(AppConstants.name)'")
            }
        #endif

        print("\nPiqley uninstalled.")
    }

    #if os(macOS)
        private func deleteKeychainItems(service: String) throws -> Int {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecItemNotFound {
                return 0
            }
            guard status == errSecSuccess else {
                throw SecretStoreError.unexpectedError(status: Int32(status))
            }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw SecretStoreError.unexpectedError(status: Int32(deleteStatus))
            }

            guard let items = result as? [[String: Any]] else { return 0 }
            return items.count
        }
    #endif
}
