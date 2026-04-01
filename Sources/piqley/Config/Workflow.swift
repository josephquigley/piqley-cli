import Foundation
import PiqleyCore

struct Workflow: Codable, Sendable {
    var name: String
    var displayName: String
    var description: String
    var schemaVersion: Int = 1
    /// Hook name -> ordered plugin identifier list.
    var pipeline: [String: [String]] = [:]
    /// Per-plugin config and secret overrides for this workflow.
    var config: [String: WorkflowPluginConfig] = [:]

    init(
        name: String,
        displayName: String,
        description: String,
        schemaVersion: Int = 1,
        pipeline: [String: [String]] = [:],
        config: [String: WorkflowPluginConfig] = [:]
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.schemaVersion = schemaVersion
        self.pipeline = pipeline
        self.config = config
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        pipeline = try container.decodeIfPresent([String: [String]].self, forKey: .pipeline) ?? [:]
        config = try container.decodeIfPresent([String: WorkflowPluginConfig].self, forKey: .config) ?? [:]
    }

    /// Creates a new empty workflow with all active stages initialized to empty arrays.
    /// Lifecycle stages (pipeline-start, pipeline-finished) are excluded as they are managed automatically.
    static func empty(name: String, displayName: String = "", description: String = "", activeStages: [String]) -> Workflow {
        let userStages = activeStages.filter { !StandardHook.requiredStageNames.contains($0) }
        return Workflow(
            name: name,
            displayName: displayName.isEmpty ? name : displayName,
            description: description,
            pipeline: Dictionary(uniqueKeysWithValues: userStages.map { ($0, [String]()) })
        )
    }

    /// Returns a copy with lifecycle stage keys removed from the pipeline.
    func strippingLifecycleStages() -> Workflow {
        var copy = self
        for stage in StandardHook.requiredStageNames {
            copy.pipeline.removeValue(forKey: stage)
        }
        return copy
    }
}
