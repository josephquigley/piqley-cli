import Foundation
import PiqleyCore

enum DependencyValidator {
    /// Validates plugin dependencies against pipeline ordering.
    /// Returns nil if valid, or an error message string if invalid.
    static func validate(
        manifests: [PluginManifest],
        pipeline: [String: [String]],
        stageOrder: [String]
    ) -> String? {
        // Check for reserved identifiers
        let reservedNames: Set<String> = [ReservedName.original, ReservedName.skip]
        for manifest in manifests where reservedNames.contains(manifest.identifier) {
            return "Plugin identifier '\(manifest.identifier)' is reserved and cannot be used."
        }

        // Build a position map: identifier → (hookIndex, positionInHook)
        let canonicalHooks = stageOrder
        var positionMap: [String: (hookIndex: Int, position: Int)] = [:]
        for (hookIndex, hookName) in canonicalHooks.enumerated() {
            let plugins = pipeline[hookName] ?? []
            for (position, pluginEntry) in plugins.enumerated() {
                let identifier = pluginEntry.split(separator: ":").first.map(String.init) ?? pluginEntry
                // First occurrence wins (a plugin may appear in multiple hooks;
                // use earliest for "runs before" check)
                if positionMap[identifier] == nil {
                    positionMap[identifier] = (hookIndex, position)
                }
            }
        }

        // Validate each manifest's dependencies
        for manifest in manifests {
            let deps = manifest.dependencyIdentifiers
            guard !deps.isEmpty else { continue }
            guard let myPos = positionMap[manifest.identifier] else { continue }

            for dep in deps {
                if dep == ReservedName.original { continue }

                guard let depPos = positionMap[dep] else {
                    return "Plugin '\(manifest.identifier)' depends on '\(dep)' which is not in the pipeline."
                }

                let depRunsBefore = depPos.hookIndex < myPos.hookIndex ||
                    (depPos.hookIndex == myPos.hookIndex && depPos.position < myPos.position)

                if !depRunsBefore {
                    return "Plugin '\(manifest.identifier)' depends on '\(dep)' but " +
                        "'\(dep)' does not run before '\(manifest.identifier)' in the pipeline."
                }
            }
        }

        return nil
    }
}
