import Foundation
import PiqleyCore

extension PluginRunner {
    func jsonValueToString(_ value: JSONValue) -> String {
        TemplateResolver().jsonValueToString(value)
    }

    // MARK: - Environment Template Resolution

    /// Resolves `{{namespace:field}}` templates in the hookConfig environment mapping
    /// against the resolved state for a given image, and merges results into the
    /// process environment.
    func resolveEnvironmentMapping(
        hookConfig: HookConfig,
        imageState: [String: [String: JSONValue]]?,
        imageName: String?,
        into env: inout [String: String]
    ) async {
        guard let mapping = hookConfig.environment else { return }
        for (envKey, template) in mapping {
            env[envKey] = await resolveTemplate(template, imageState: imageState, imageName: imageName)
        }
    }

    /// Resolves a single template string, replacing all `{{namespace:field}}` references
    /// with their values from the image state. `self` is expanded to the current
    /// plugin's identifier. The `read` namespace loads live file metadata via MetadataBuffer.
    func resolveTemplate(
        _ template: String,
        imageState: [String: [String: JSONValue]]?,
        imageName: String?
    ) async -> String {
        let ctx = TemplateResolver.Context(
            state: imageState ?? [:],
            metadataBuffer: metadataBuffer,
            imageName: imageName,
            pluginId: plugin.identifier,
            logger: logger
        )
        return await TemplateResolver().resolve(template, context: ctx)
    }
}
