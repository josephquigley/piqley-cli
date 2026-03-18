import Foundation

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

    /// All image filenames that have state stored.
    var allImageNames: [String] {
        Array(images.keys)
    }
}
