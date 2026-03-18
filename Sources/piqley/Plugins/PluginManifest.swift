import Foundation

struct PluginManifest: Codable, Sendable {
    let name: String
    let pluginProtocolVersion: String
    let secrets: [String]
    let hooks: [String: HookConfig]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        pluginProtocolVersion = try container.decode(String.self, forKey: .pluginProtocolVersion)
        secrets = (try? container.decode([String].self, forKey: .secrets)) ?? []
        hooks = try container.decode([String: HookConfig].self, forKey: .hooks)
    }

    private enum CodingKeys: String, CodingKey {
        case name, pluginProtocolVersion, secrets, hooks
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
