import Foundation

struct PluginManifest: Codable, Sendable {
    let name: String
    let pluginProtocolVersion: String
    let config: [ConfigEntry]
    let setup: SetupConfig?
    let dependencies: [String]?
    let hooks: [String: HookConfig]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        pluginProtocolVersion = try container.decode(String.self, forKey: .pluginProtocolVersion)
        config = (try? container.decode([ConfigEntry].self, forKey: .config)) ?? []
        setup = try? container.decodeIfPresent(SetupConfig.self, forKey: .setup)
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies)
        hooks = try container.decode([String: HookConfig].self, forKey: .hooks)
    }

    init(
        name: String, pluginProtocolVersion: String, config: [ConfigEntry] = [],
        setup: SetupConfig? = nil, dependencies: [String]? = nil, hooks: [String: HookConfig]
    ) {
        self.name = name
        self.pluginProtocolVersion = pluginProtocolVersion
        self.config = config
        self.setup = setup
        self.dependencies = dependencies
        self.hooks = hooks
    }

    private enum CodingKeys: String, CodingKey {
        case name, pluginProtocolVersion, config, setup, dependencies, hooks
    }

    /// Returns secret key names from config entries with `secret_key`.
    var secretKeys: [String] {
        config.compactMap { entry in
            if case let .secret(secretKey, _) = entry { return secretKey }
            return nil
        }
    }

    /// Returns value entries as tuples for easy iteration.
    var valueEntries: [(key: String, type: ConfigValueType, value: JSONValue)] {
        config.compactMap { entry in
            if case let .value(key, type, value) = entry { return (key, type, value) }
            return nil
        }
    }

    struct HookConfig: Codable, Sendable {
        let command: String
        let args: [String]
        let timeout: Int?
        let pluginProtocol: PluginProtocol?
        let successCodes: [Int32]?
        let warningCodes: [Int32]?
        let criticalCodes: [Int32]?
        let batchProxy: BatchProxyConfig?

        private enum CodingKeys: String, CodingKey {
            case command, args, timeout
            case pluginProtocol = "protocol"
            case successCodes, warningCodes, criticalCodes, batchProxy
        }

        func makeEvaluator() -> ExitCodeEvaluator {
            ExitCodeEvaluator(
                successCodes: successCodes,
                warningCodes: warningCodes,
                criticalCodes: criticalCodes
            )
        }
    }

    enum SortOrder: String, Codable, Sendable {
        case ascending, descending
    }

    struct SortConfig: Codable, Sendable {
        let key: String
        let order: SortOrder
    }

    struct BatchProxyConfig: Codable, Sendable {
        let sort: SortConfig?
    }

    enum PluginProtocol: String, Codable, Sendable {
        case json
        case pipe
    }

    /// The canonical set of hook names piqley recognises.
    static let canonicalHooks: [String] = ["pre-process", "post-process", "publish", "schedule", "post-publish"]

    /// Returns hook names in this manifest that are not canonical (for warning).
    func unknownHooks() -> [String] {
        hooks.keys.filter { !Self.canonicalHooks.contains($0) }
    }
}
