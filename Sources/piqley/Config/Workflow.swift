import Foundation
import PiqleyCore

struct Workflow: Codable, Sendable {
    var name: String
    var displayName: String
    var description: String
    var schemaVersion: Int = 1
    /// Hook name -> ordered plugin identifier list.
    var pipeline: [String: [String]] = [:]

    /// Creates a new empty workflow with all four hooks initialized to empty arrays.
    static func empty(name: String, displayName: String = "", description: String = "") -> Workflow {
        Workflow(
            name: name,
            displayName: displayName.isEmpty ? name : displayName,
            description: description,
            pipeline: Dictionary(uniqueKeysWithValues: Hook.canonicalOrder.map { ($0.rawValue, [String]()) })
        )
    }
}
