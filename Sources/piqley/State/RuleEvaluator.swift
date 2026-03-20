import Foundation
import Logging
import PiqleyCore

enum EmitAction: Sendable {
    case skip
    case add(field: String, values: [String])
    case remove(field: String, matchers: [any TagMatcher & Sendable])
    case replace(field: String, replacements: [(matcher: any TagMatcher & Sendable, replacement: String)])
    case removeField(field: String) // "*" means remove all fields
    case clone(field: String, sourceNamespace: String, sourceField: String?)
}

struct CompiledRule: Sendable {
    let namespace: String // match-side namespace
    let field: String // match-side field
    let matcher: any TagMatcher & Sendable
    let emitActions: [EmitAction]
    let writeActions: [EmitAction]
}

enum RuleCompilationError: Error, LocalizedError {
    case invalidRegex(ruleIndex: Int, pattern: String, underlying: Error)
    case invalidEmit(ruleIndex: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRegex(ruleIndex, pattern, err):
            "Rule \(ruleIndex): invalid regex '\(pattern)': \(err.localizedDescription)"
        case let .invalidEmit(ruleIndex, reason):
            "Rule \(ruleIndex): invalid emit: \(reason)"
        }
    }
}

struct RuleEvaluationResult: Sendable {
    let namespace: [String: JSONValue]
    let skipped: Bool
}

struct RuleEvaluator: Sendable {
    let compiledRules: [CompiledRule]

    /// Compiles rules. If nonInteractive, invalid rules are skipped with warnings logged.
    /// Otherwise, errors are thrown.
    init(rules: [Rule], nonInteractive: Bool = false, logger: Logger) throws {
        var compiled: [CompiledRule] = []
        for (index, rule) in rules.enumerated() {
            // Parse field: split on first ":"
            let (namespace, field) = Self.splitField(rule.match.field)

            // Compile match pattern
            let matcher: any TagMatcher & Sendable
            do {
                matcher = try TagMatcherFactory.build(from: rule.match.pattern)
            } catch {
                let compError = RuleCompilationError.invalidRegex(
                    ruleIndex: index, pattern: rule.match.pattern, underlying: error
                )
                if nonInteractive {
                    logger.warning("\(compError.localizedDescription) — skipping rule")
                    continue
                }
                throw compError
            }

            // Compile emit actions
            var emitActions: [EmitAction] = []
            do {
                for emitConfig in rule.emit {
                    let action = try Self.compileEmitAction(emitConfig, ruleIndex: index)
                    emitActions.append(action)
                }
            } catch {
                if nonInteractive {
                    logger.warning("\(error.localizedDescription) — skipping rule")
                    continue
                }
                throw error
            }

            // Compile write actions
            var writeActions: [EmitAction] = []
            do {
                for writeConfig in rule.write {
                    let action = try Self.compileEmitAction(writeConfig, ruleIndex: index)
                    writeActions.append(action)
                }
            } catch {
                if nonInteractive {
                    logger.warning("\(error.localizedDescription) — skipping rule")
                    continue
                }
                throw error
            }

            compiled.append(CompiledRule(
                namespace: namespace,
                field: field,
                matcher: matcher,
                emitActions: emitActions,
                writeActions: writeActions
            ))
        }
        compiledRules = compiled
    }

    private static func compileEmitAction(_ config: EmitConfig, ruleIndex: Int) throws -> EmitAction {
        if case let .failure(error) = RuleValidator.validateEmit(config) {
            throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: error.errorDescription ?? "invalid emit")
        }

        let actionStr = config.action ?? "add"

        switch actionStr {
        case "skip":
            return .skip

        case "add":
            guard let field = config.field else {
                throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for add")
            }
            let values = config.values!
            return .add(field: field, values: values)

        case "remove":
            guard let field = config.field else {
                throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for remove")
            }
            let values = config.values!
            let matchers: [any TagMatcher & Sendable] = try values.map { entry in
                try TagMatcherFactory.build(from: entry)
            }
            return .remove(field: field, matchers: matchers)

        case "replace":
            guard let field = config.field else {
                throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for replace")
            }
            let replacements = config.replacements!
            let compiled: [(matcher: any TagMatcher & Sendable, replacement: String)] = try replacements.map { entry in
                let matcher = try TagMatcherFactory.build(from: entry.pattern)
                return (matcher: matcher, replacement: entry.replacement)
            }
            return .replace(field: field, replacements: compiled)

        case "removeField":
            guard let field = config.field else {
                throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for removeField")
            }
            return .removeField(field: field)

        case "clone":
            guard let field = config.field else {
                throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "field required for clone")
            }
            let source = config.source!
            if field == "*" {
                // Wildcard clone: source is the namespace name
                return .clone(field: "*", sourceNamespace: source, sourceField: nil)
            } else {
                let (namespace, sourceField) = splitField(source)
                guard !namespace.isEmpty, !sourceField.isEmpty else {
                    throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "clone source must be 'namespace:field'")
                }
                return .clone(field: field, sourceNamespace: namespace, sourceField: sourceField)
            }

        default:
            // unreachable: RuleValidator.validateEmit rejects unknown actions above
            throw RuleCompilationError.invalidEmit(ruleIndex: ruleIndex, reason: "unknown action '\(actionStr)'")
        }
    }

    /// Evaluate rules for a given hook against resolved state.
    /// state is [namespace: [field: JSONValue]]
    /// currentNamespace is the plugin's current emitted state.
    /// metadataBuffer is used to resolve read: namespace fields and apply write actions.
    /// Returns the complete updated namespace (untouched fields preserved).
    func evaluate(
        state: [String: [String: JSONValue]],
        currentNamespace: [String: JSONValue] = [:],
        metadataBuffer: MetadataBuffer? = nil,
        imageName: String? = nil,
        pluginId: String? = nil,
        stateStore: StateStore? = nil
    ) async -> RuleEvaluationResult {
        var working = currentNamespace
        var skipped = false

        for rule in compiledRules {
            // Resolve the match field value
            let value: JSONValue?
            if rule.namespace == "read", let buffer = metadataBuffer, let image = imageName {
                let fileMetadata = await buffer.load(image: image)
                value = fileMetadata[rule.field]
            } else {
                value = state[rule.namespace]?[rule.field]
            }

            guard let value else { continue }

            let matched: Bool = switch value {
            case let .string(str):
                rule.matcher.matches(str)
            case let .array(arr):
                arr.contains { element in
                    if case let .string(str) = element {
                        return rule.matcher.matches(str)
                    }
                    return false
                }
            default:
                false
            }

            if matched {
                // Emit actions first (modify plugin namespace)
                var didSkip = false
                for action in rule.emitActions {
                    if case .skip = action {
                        if let store = stateStore, let image = imageName, let plugin = pluginId {
                            let record = JSONValue.object(["file": .string(image), "plugin": .string(plugin)])
                            await store.appendSkipRecord(image: image, record: record)
                        }
                        didSkip = true
                        break
                    }
                    if case let .clone(field, sourceNamespace, sourceField) = action {
                        // Clone is handled inline because it needs access to state and metadataBuffer
                        if sourceNamespace == "read", let buffer = metadataBuffer, let image = imageName {
                            let fileMetadata = await buffer.load(image: image)
                            if field == "*" {
                                for (key, val) in fileMetadata {
                                    working[key] = val
                                }
                            } else if let sourceField, let val = fileMetadata[sourceField] {
                                working[field] = val
                            }
                        } else if field == "*" {
                            if let namespaceData = state[sourceNamespace] {
                                for (key, val) in namespaceData {
                                    working[key] = val
                                }
                            }
                        } else if let sourceField, let val = state[sourceNamespace]?[sourceField] {
                            working[field] = val
                        }
                        continue
                    }
                    Self.applyAction(action, to: &working)
                }

                if didSkip {
                    skipped = true
                    break
                }

                // Write actions second (modify file metadata via buffer)
                if let buffer = metadataBuffer, let image = imageName {
                    for action in rule.writeActions {
                        await buffer.applyAction(action, image: image)
                    }
                }
            }
        }

        return RuleEvaluationResult(namespace: working, skipped: skipped)
    }

    static func applyAction(_ action: EmitAction, to working: inout [String: JSONValue]) {
        switch action {
        case .skip:
            // Skip is handled by evaluate(); no-op here.
            break

        case let .add(field, values):
            var existing = extractStrings(from: working[field])
            for val in values where !existing.contains(val) {
                existing.append(val)
            }
            working[field] = .array(existing.map { .string($0) })

        case let .remove(field, matchers):
            var existing = extractStrings(from: working[field])
            existing.removeAll { value in
                matchers.contains { $0.matches(value) }
            }
            if existing.isEmpty {
                working.removeValue(forKey: field)
            } else {
                working[field] = .array(existing.map { .string($0) })
            }

        case let .replace(field, replacements):
            var existing = extractStrings(from: working[field])
            existing = existing.map { value in
                for (matcher, replacement) in replacements {
                    let result = matcher.replacing(value, with: replacement)
                    if result != value {
                        return result
                    }
                }
                return value
            }
            working[field] = .array(existing.map { .string($0) })

        case let .removeField(field):
            if field == "*" {
                working.removeAll()
            } else {
                working.removeValue(forKey: field)
            }

        case .clone:
            // Clone is handled inline in evaluate(), not via applyAction.
            break
        }
    }

    private static func extractStrings(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case let .string(str):
            return [str]
        case let .array(arr):
            return arr.compactMap { element in
                if case let .string(str) = element { return str }
                return nil
            }
        default:
            return []
        }
    }

    private static func splitField(_ field: String) -> (namespace: String, field: String) {
        guard let colonIndex = field.firstIndex(of: ":") else {
            return ("", field)
        }
        let namespace = String(field[field.startIndex ..< colonIndex])
        let fieldName = String(field[field.index(after: colonIndex)...])
        return (namespace, fieldName)
    }
}
