#if !os(macOS)
    import Foundation

    struct FileSecretStore: SecretStore {
        private let fileURL: URL

        init() {
            fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(PiqleyPath.secrets)
        }

        init(fileURL: URL) {
            self.fileURL = fileURL
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

        private func loadSecrets() throws -> [String: String] {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        }

        private func saveSecrets(_ secrets: [String: String]) throws {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(secrets)
            try data.write(to: fileURL, options: .atomic)
            chmod(fileURL.path, 0o600)
        }
    }
#endif
