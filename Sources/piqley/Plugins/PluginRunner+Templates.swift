import Foundation
import PiqleyCore

extension PluginRunner {
    func jsonValueToString(_ value: JSONValue) -> String {
        switch value {
        case let .string(str): str
        case let .number(num):
            if num.truncatingRemainder(dividingBy: 1) == 0 {
                String(Int(num))
            } else {
                String(num)
            }
        case let .bool(flag): String(flag)
        case let .array(arr):
            arr.map { jsonValueToString($0) }.joined(separator: ",")
        default: ""
        }
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
        var result = template
        while let openRange = result.range(of: "{{"),
              let closeRange = result.range(of: "}}", range: openRange.upperBound ..< result.endIndex)
        {
            let reference = String(result[openRange.upperBound ..< closeRange.lowerBound])
            let resolved = await resolveFieldReference(reference, imageState: imageState, imageName: imageName)
            result.replaceSubrange(openRange.lowerBound ..< closeRange.upperBound, with: resolved)
        }
        return result
    }

    private func resolveFieldReference(
        _ reference: String,
        imageState: [String: [String: JSONValue]]?,
        imageName: String?
    ) async -> String {
        guard let colonIndex = reference.firstIndex(of: ":") else {
            logger.warning("Invalid environment template reference '\(reference)' — missing ':'")
            return ""
        }
        var namespace = String(reference[reference.startIndex ..< colonIndex])
        let field = String(reference[reference.index(after: colonIndex)...])

        if namespace == "self" {
            namespace = plugin.identifier
        }

        // The "read" namespace reads live file metadata via MetadataBuffer
        if namespace == "read", let buffer = metadataBuffer, let imageName {
            let fileMetadata = await buffer.load(image: imageName)
            if let value = fileMetadata[field] {
                return jsonValueToString(value)
            }
            logger.warning(
                "[\(plugin.name)] Environment template '{{\(reference)}}' resolved to empty — field not found in file metadata"
            )
            return ""
        }

        // If the parsed namespace exists in state, use it directly.
        if let namespaceState = imageState?[namespace],
           let value = namespaceState[field]
        {
            return jsonValueToString(value)
        }

        // Fallback: the namespace part may actually be part of a colon-delimited
        // field name (e.g., "IPTC:Keywords") rather than a state namespace.
        // Try the full reference as a field name in the plugin's own namespace.
        if imageState?[namespace] == nil {
            let selfNamespace = plugin.identifier
            if let value = imageState?[selfNamespace]?[reference] {
                return jsonValueToString(value)
            }
        }

        logger.warning(
            "[\(plugin.name)] Environment template '{{\(reference)}}' resolved to empty — field not found in state"
        )
        return ""
    }
}
