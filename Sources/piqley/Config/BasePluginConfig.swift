import Foundation
import PiqleyCore

struct BasePluginConfig: Codable, Sendable, Equatable {
    var values: [String: JSONValue]
    var secrets: [String: String]
    var isSetUp: Bool?

    init(
        values: [String: JSONValue] = [:],
        secrets: [String: String] = [:],
        isSetUp: Bool? = nil
    ) {
        self.values = values
        self.secrets = secrets
        self.isSetUp = isSetUp
    }

    func merging(_ overrides: WorkflowPluginConfig) -> BasePluginConfig {
        var merged = self
        if let overrideValues = overrides.values {
            merged.values.merge(overrideValues) { _, new in new }
        }
        if let overrideSecrets = overrides.secrets {
            merged.secrets.merge(overrideSecrets) { _, new in new }
        }
        return merged
    }
}

struct WorkflowPluginConfig: Codable, Sendable, Equatable {
    var values: [String: JSONValue]?
    var secrets: [String: String]?
}
