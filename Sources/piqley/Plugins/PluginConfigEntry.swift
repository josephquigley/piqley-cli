import Foundation

/// The type of a config entry value.
enum ConfigValueType: String, Codable, Sendable {
    case string
    case int
    case float
    case bool
}

/// A single entry in a plugin's `config` array.
/// Either a regular value (`key`/`value`) or a secret (`secret_key`).
enum ConfigEntry: Codable, Sendable {
    case value(key: String, type: ConfigValueType, value: JSONValue)
    case secret(secretKey: String, type: ConfigValueType)

    private enum CodingKeys: String, CodingKey {
        case key, secretKey = "secret_key", type, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ConfigValueType.self, forKey: .type)
        let hasKey = container.contains(.key)
        let hasSecretKey = container.contains(.secretKey)

        if hasKey, hasSecretKey {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Config entry must have exactly one of 'key' or 'secret_key', not both"
                )
            )
        }

        if let secretKey = try container.decodeIfPresent(String.self, forKey: .secretKey) {
            self = .secret(secretKey: secretKey, type: type)
        } else if let key = try container.decodeIfPresent(String.self, forKey: .key) {
            let value = try container.decode(JSONValue.self, forKey: .value)
            self = .value(key: key, type: type, value: value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Config entry must have exactly one of 'key' or 'secret_key'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .value(key, type, value):
            try container.encode(key, forKey: .key)
            try container.encode(type, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .secret(secretKey, type):
            try container.encode(secretKey, forKey: .secretKey)
            try container.encode(type, forKey: .type)
        }
    }
}

/// Optional setup binary configuration in the plugin manifest.
struct SetupConfig: Codable, Sendable {
    let command: String
    let args: [String]

    init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case command, args
    }
}
