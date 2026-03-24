import Foundation
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

    // MARK: - Upstream Discovery

    /// Discovers emitted fields from upstream plugins by scanning their rules JSON files.
    ///
    /// "Upstream" means: all plugins in stages before the target's stage, plus plugins
    /// earlier in the same stage's array. The target plugin itself is also included.
    ///
    /// - Parameters:
    ///   - pipeline: The workflow pipeline dictionary (stage name -> ordered plugin IDs).
    ///   - targetPlugin: The plugin identifier being edited.
    ///   - stageOrder: The ordered list of active stage names.
    ///   - rulesBaseDir: The workflow's rules base directory.
    /// - Returns: An array of `DependencyInfo` for each upstream plugin that has emitted fields.
    static func discoverUpstreamFields(
        pipeline: [String: [String]],
        targetPlugin: String,
        stageOrder: [String],
        rulesBaseDir: URL
    ) -> [DependencyInfo] {
        // 1. Find target's stage and position
        var targetStageIndex = stageOrder.count
        var targetPosition = 0
        for (stageIdx, stage) in stageOrder.enumerated() {
            let plugins = pipeline[stage] ?? []
            if let pos = plugins.firstIndex(of: targetPlugin) {
                targetStageIndex = stageIdx
                targetPosition = pos
                break
            }
        }

        // 2. Collect upstream plugins and which stages they're upstream in
        // Key: pluginId, Value: set of stage names where they're upstream
        var upstreamStages: [(identifier: String, stages: Set<String>)] = []
        var seen: [String: Int] = [:] // pluginId -> index in upstreamStages

        for (stageIdx, stage) in stageOrder.enumerated() {
            guard stageIdx <= targetStageIndex else { break }
            let plugins = pipeline[stage] ?? []

            for (pluginIdx, pluginId) in plugins.enumerated() {
                // Skip plugins that aren't upstream
                if stageIdx == targetStageIndex, pluginId != targetPlugin, pluginIdx >= targetPosition {
                    continue
                }

                if let existingIdx = seen[pluginId] {
                    upstreamStages[existingIdx].stages.insert(stage)
                } else {
                    seen[pluginId] = upstreamStages.count
                    upstreamStages.append((identifier: pluginId, stages: [stage]))
                }
            }
        }

        // 3. Harvest fields from each upstream plugin's rules files
        var result: [DependencyInfo] = []
        for entry in upstreamStages {
            var fields: Set<String> = []
            for stage in entry.stages {
                let filename = "\(PluginFile.stagePrefix)\(stage)\(PluginFile.stageSuffix)"
                let fileURL = rulesBaseDir
                    .appendingPathComponent(entry.identifier)
                    .appendingPathComponent(filename)

                guard let data = try? Data(contentsOf: fileURL),
                      let stageConfig = try? JSONDecoder.piqley.decode(StageConfig.self, from: data)
                else { continue }

                let allRules = (stageConfig.preRules ?? []) + (stageConfig.postRules ?? [])
                for rule in allRules {
                    for emit in rule.emit {
                        if let field = emit.field, field != "*" {
                            fields.insert(field)
                        }
                    }
                }
            }

            if !fields.isEmpty {
                result.append(DependencyInfo(
                    identifier: entry.identifier,
                    fields: Array(fields)
                ))
            }
        }

        return result
    }
}
