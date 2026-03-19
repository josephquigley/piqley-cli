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
    /// Build FieldInfo entries for a metadata source ("original" or "read")
    /// by aggregating all catalog categories and prefixing qualifiedName with the source.
    private static func catalogFields(forSource sourceName: String) -> [FieldInfo] {
        ["exif", "iptc", "xmp", "tiff"].flatMap { catalogSource in
            MetadataFieldCatalog.fields(forSource: catalogSource).map { field in
                // field.qualifiedName is e.g. "EXIF:ISO" — prefix with source
                FieldInfo(
                    name: field.qualifiedName,
                    source: sourceName,
                    qualifiedName: "\(sourceName):\(field.qualifiedName)",
                    category: field.category
                )
            }
        }.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            return lhs.name < rhs.name
        }
    }

    static func buildAvailableFields(dependencies: [DependencyInfo]) -> [String: [FieldInfo]] {
        var result: [String: [FieldInfo]] = [:]
        result["original"] = catalogFields(forSource: "original")
        result["read"] = catalogFields(forSource: "read")

        for dep in dependencies {
            result[dep.identifier] = dep.fields.sorted().map { name in
                FieldInfo(name: name, source: dep.identifier, category: .custom)
            }
        }

        return result
    }
}
