#if !os(macOS)
    import Foundation
    import PiqleyCore

    struct FileSecretStore: SecretStore {
        private let fileURL: URL
        private let fileManager: any FileSystemManager

        init(fileManager: any FileSystemManager = FileManager.default) {
            fileURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(PiqleyPath.secrets)
            self.fileManager = fileManager
        }

        init(fileURL: URL, fileManager: any FileSystemManager = FileManager.default) {
            self.fileURL = fileURL
            self.fileManager = fileManager
        }

        func get(key: String) throws -> String {
            let secrets = try loadSecrets()
            guard let value = secrets[key] else {
                throw SecretStoreError.notFound(key: key)
            }
            return value
        }

        func set(key: String, value: String) throws {
            var secrets = (try? loadSecrets()) ?? [:]
            secrets[key] = value
            try saveSecrets(secrets)
        }

        func delete(key: String) throws {
            var secrets = (try? loadSecrets()) ?? [:]
            secrets.removeValue(forKey: key)
            try saveSecrets(secrets)
        }

        func list() throws -> [String] {
            let dict = (try? loadSecrets()) ?? [:]
            return Array(dict.keys)
        }

        private func loadSecrets() throws -> [String: String] {
            let data = try fileManager.contents(of: fileURL)
            return try JSONDecoder.piqley.decode([String: String].self, from: data)
        }

        private func saveSecrets(_ secrets: [String: String]) throws {
            let dir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.piqley.encode(secrets)
            try fileManager.write(data, to: fileURL, options: .atomic)
            chmod(fileURL.path, 0o600)
        }
    }
#endif
