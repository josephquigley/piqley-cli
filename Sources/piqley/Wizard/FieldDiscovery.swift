import PiqleyCore

// MARK: - FieldDiscovery

/// Builds the available fields dictionary for the rule editor wizard.
///
/// Combines all standard metadata fields from the `MetadataFieldCatalog` under
/// the "original" and "read" namespace keys, then adds one entry per dependency
/// plugin keyed by its identifier.
enum FieldDiscovery {
    // MARK: - DependencyInfo

    /// Describes the fields exposed by a dependency plugin.
    struct DependencyInfo {
        /// The plugin's unique identifier, used as the dictionary key.
        let identifier: String
        /// The bare field names exposed by this plugin.
        let fields: [String]
    }

    // MARK: - buildAvailableFields

    /// Returns a dictionary of available fields, keyed by source namespace.
    ///
    /// - "original": all fields from every `MetadataSource` in the catalog.
    /// - "read": identical to "original" (same set of readable fields).
    /// - Each dependency identifier: its fields, sorted alphabetically.
    ///
    /// - Parameter dependencies: Plugin dependencies whose fields should be included.
    /// - Returns: A dictionary mapping source names to their `FieldInfo` arrays.
    static func buildAvailableFields(dependencies: [DependencyInfo]) -> [String: [FieldInfo]] {
        let standardFields: [FieldInfo] = MetadataSource.allCases.flatMap { source in
            MetadataFieldCatalog.fields(forSource: source)
        }

        var result: [String: [FieldInfo]] = [:]
        result["original"] = standardFields
        result["read"] = standardFields

        for dep in dependencies {
            result[dep.identifier] = dep.fields.sorted().map { name in
                FieldInfo(name: name, source: .exif)
            }
        }

        return result
    }
}
