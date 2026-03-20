import Foundation
import PiqleyCore

/// Per-pipeline-run, in-memory state store. Namespaced per image, per plugin.
actor StateStore {
    private var images: [String: [String: [String: JSONValue]]] = [:]

    /// Store values under a plugin's namespace for a specific image.
    /// Replaces any previous values for this plugin+image combination.
    func setNamespace(image: String, plugin: String, values: [String: JSONValue]) {
        if images[image] == nil {
            images[image] = [:]
        }
        images[image]![plugin] = values
    }

    /// Merges values into a plugin's namespace for a specific image.
    /// New keys are added, existing keys are overwritten. Keys not in `values` are preserved.
    func mergeNamespace(image: String, plugin: String, values: [String: JSONValue]) {
        if images[image] == nil {
            images[image] = [:]
        }
        if images[image]![plugin] == nil {
            images[image]![plugin] = values
        } else {
            for (key, value) in values {
                images[image]![plugin]![key] = value
            }
        }
    }

    /// Resolve state for an image, returning only namespaces listed in dependencies.
    func resolve(image: String, dependencies: [String]) -> [String: [String: JSONValue]] {
        guard let namespaces = images[image] else { return [:] }
        var result: [String: [String: JSONValue]] = [:]
        for dep in dependencies {
            if let values = namespaces[dep] {
                result[dep] = values
            }
        }
        return result
    }

    /// Appends a skip record for an image to the reserved skip namespace.
    func appendSkipRecord(image: String, record: JSONValue) {
        if images[image] == nil {
            images[image] = [:]
        }
        if images[image]![ReservedName.skip] == nil {
            images[image]![ReservedName.skip] = [:]
        }
        var existing: [JSONValue] = []
        if case let .array(arr) = images[image]![ReservedName.skip]![ReservedName.skipRecords] {
            existing = arr
        }
        existing.append(record)
        images[image]![ReservedName.skip]![ReservedName.skipRecords] = .array(existing)
    }

    /// All image filenames that have state stored.
    var allImageNames: [String] {
        Array(images.keys)
    }
}
