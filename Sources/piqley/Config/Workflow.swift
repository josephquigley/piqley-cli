import Foundation
import PiqleyCore

struct Workflow: Codable, Sendable {
    var name: String
    var displayName: String
    var description: String
    var schemaVersion: Int = 1
    /// Hook name -> ordered plugin identifier list.
    var pipeline: [String: [String]] = [:]

    /// Creates a new empty workflow with all active stages initialized to empty arrays.
    static func empty(name: String, displayName: String = "", description: String = "", activeStages: [String]) -> Workflow {
        Workflow(
            name: name,
            displayName: displayName.isEmpty ? name : displayName,
            description: description,
            pipeline: Dictionary(uniqueKeysWithValues: activeStages.map { ($0, [String]()) })
        )
    }
}
