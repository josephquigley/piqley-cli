import Foundation
import PiqleyCore

struct ResolvedPluginConfig: Sendable {
    let values: [String: JSONValue]
    let secrets: [String: String]

    func toEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in values {
            let envKey = "PIQLEY_CONFIG_\(Self.sanitizeKey(key))"
            env[envKey] = value.stringRepresentation
        }
        for (key, value) in secrets {
            let envKey = "PIQLEY_SECRET_\(Self.sanitizeKey(key))"
            env[envKey] = value
        }
        return env
    }

    /// Converts a config/secret key into a valid environment variable suffix.
    /// Uppercases, replaces hyphens and dots with underscores, strips other non-alphanumeric characters.
    static func sanitizeKey(_ key: String) -> String {
        key.uppercased()
            .replacing("-", with: "_")
            .replacing(".", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

enum ConfigResolver {
    static func resolve(
        base: BasePluginConfig,
        workflowOverrides: WorkflowPluginConfig?,
        secretStore: any SecretStore
    ) throws -> ResolvedPluginConfig {
        let merged: BasePluginConfig = if let overrides = workflowOverrides {
            base.merging(overrides)
        } else {
            base
        }

        var resolvedSecrets: [String: String] = [:]
        for (key, alias) in merged.secrets {
            resolvedSecrets[key] = try secretStore.get(key: alias)
        }

        return ResolvedPluginConfig(
            values: merged.values,
            secrets: resolvedSecrets
        )
    }
}

// MARK: - JSONValue environment variable conversion

extension JSONValue {
    /// Returns a string representation suitable for use as an environment variable value.
    var stringRepresentation: String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            // Use integer formatting when the number has no fractional part
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(Int(value))
            }
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return ""
        case let .array(values):
            return values.map(\.stringRepresentation).joined(separator: ",")
        case let .object(dict):
            // JSON-encode objects for env var use
            let pairs = dict.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value.stringRepresentation)" }
            return pairs.joined(separator: ",")
        }
    }
}
