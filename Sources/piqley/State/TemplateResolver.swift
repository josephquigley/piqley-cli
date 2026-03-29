import Foundation
import Logging
import PiqleyCore

struct TemplateResolver: Sendable {
    struct Context {
        var state: [String: [String: JSONValue]]
        var metadataBuffer: MetadataBuffer?
        var imageName: String?
        var pluginId: String?
        var logger: Logger

        init(
            state: [String: [String: JSONValue]],
            metadataBuffer: MetadataBuffer? = nil,
            imageName: String? = nil,
            pluginId: String? = nil,
            logger: Logger
        ) {
            self.state = state
            self.metadataBuffer = metadataBuffer
            self.imageName = imageName
            self.pluginId = pluginId
            self.logger = logger
        }
    }

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

    func resolve(_ template: String, context: Context) async -> String {
        var result = template
        while let openRange = result.range(of: "{{"),
              let closeRange = result.range(of: "}}", range: openRange.upperBound ..< result.endIndex)
        {
            let reference = String(result[openRange.upperBound ..< closeRange.lowerBound])
            let resolved = await resolveFieldReference(reference, context: context)
            result.replaceSubrange(openRange.lowerBound ..< closeRange.upperBound, with: resolved)
        }
        return result
    }

    private func resolveFieldReference(_ reference: String, context: Context) async -> String {
        guard let colonIndex = reference.firstIndex(of: ":") else {
            context.logger.warning("Invalid template reference '\(reference)' — missing ':'")
            return ""
        }
        var namespace = String(reference[reference.startIndex ..< colonIndex])
        let field = String(reference[reference.index(after: colonIndex)...])

        if namespace == "self" {
            guard let pluginId = context.pluginId else {
                context.logger.warning("Template reference '{{\(reference)}}' uses 'self' but no pluginId provided")
                return ""
            }
            namespace = pluginId
        }

        if namespace == "read", let buffer = context.metadataBuffer, let imageName = context.imageName {
            let fileMetadata = await buffer.load(image: imageName)
            if let value = fileMetadata[field] {
                return jsonValueToString(value)
            }
            context.logger.warning("Template '{{\(reference)}}' resolved to empty — field not found in file metadata")
            return ""
        }

        if let namespaceState = context.state[namespace], let value = namespaceState[field] {
            return jsonValueToString(value)
        }

        // Fallback: colon-delimited field name in plugin's own namespace
        if context.state[namespace] == nil, let pluginId = context.pluginId {
            if let value = context.state[pluginId]?[reference] {
                return jsonValueToString(value)
            }
        }

        context.logger.warning("Template '{{\(reference)}}' resolved to empty — field not found in state")
        return ""
    }
}
