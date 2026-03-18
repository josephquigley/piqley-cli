import Foundation

enum DependencyValidator {
    /// Validates plugin dependencies against pipeline ordering.
    /// Returns nil if valid, or an error message string if invalid.
    static func validate(
        manifests: [PluginManifest],
        pipeline: [String: [String]]
    ) -> String? {
        // Check for reserved name "original"
        for manifest in manifests where manifest.name == "original" {
            return "Plugin name 'original' is reserved and cannot be used."
        }

        // Build a position map: pluginName → (hookIndex, positionInHook)
        let canonicalHooks = PluginManifest.canonicalHooks
        var positionMap: [String: (hookIndex: Int, position: Int)] = [:]
        for (hookIndex, hookName) in canonicalHooks.enumerated() {
            let plugins = pipeline[hookName] ?? []
            for (position, pluginName) in plugins.enumerated() {
                let name = pluginName.split(separator: ":").first.map(String.init) ?? pluginName
                // First occurrence wins (a plugin may appear in multiple hooks;
                // use earliest for "runs before" check)
                if positionMap[name] == nil {
                    positionMap[name] = (hookIndex, position)
                }
            }
        }

        // Validate each manifest's dependencies
        for manifest in manifests {
            guard let deps = manifest.dependencies, !deps.isEmpty else { continue }
            guard let myPos = positionMap[manifest.name] else { continue }

            for dep in deps {
                if dep == "original" { continue }

                guard let depPos = positionMap[dep] else {
                    return "Plugin '\(manifest.name)' depends on '\(dep)' which is not in the pipeline."
                }

                let depRunsBefore = depPos.hookIndex < myPos.hookIndex ||
                    (depPos.hookIndex == myPos.hookIndex && depPos.position < myPos.position)

                if !depRunsBefore {
                    return "Plugin '\(manifest.name)' depends on '\(dep)' but '\(dep)' does not run before '\(manifest.name)' in the pipeline."
                }
            }
        }

        return nil
    }
}
