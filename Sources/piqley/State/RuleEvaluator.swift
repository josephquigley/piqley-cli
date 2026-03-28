import Foundation
import Logging
import PiqleyCore

enum EmitAction: Sendable {
    case skip
    case add(field: String, values: [String])
    case remove(field: String, matchers: [any TagMatcher & Sendable], not: Bool)
    case replace(field: String, replacements: [(matcher: any TagMatcher & Sendable, replacement: String)])
    case removeField(field: String, not: Bool)
    case clone(field: String, sourceNamespace: String, sourceField: String?)
    case writeBack
}

struct CompiledRule: Sendable {
    let unconditional: Bool
    let namespace: String // match-side namespace
    let field: String // match-side field
    let matcher: (any TagMatcher & Sendable)?
    let not: Bool
    let emitActions: [EmitAction]
    let writeActions: [EmitAction]
}

enum RuleCompilationError: Error, LocalizedError {
    case invalidRegex(ruleIndex: Int, pattern: String, underlying: Error)
    case invalidEmit(ruleIndex: Int, reason: String)
    case unresolvedSelf(ruleIndex: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidRegex(ruleIndex, pattern, err):
            "Rule \(ruleIndex): invalid regex '\(pattern)': \(err.localizedDescription)"
        case let .invalidEmit(ruleIndex, reason):
            "Rule \(ruleIndex): invalid emit: \(reason)"
        case let .unresolvedSelf(ruleIndex):
            "Rule \(ruleIndex): 'self' namespace requires a pluginId but none was provided"
        }
    }
}

struct RuleEvaluationResult: Sendable {
    let namespace: [String: JSONValue]
    let skipped: Bool
}

struct RuleEvaluator: Sendable {
    let compiledRules: [CompiledRule]
    let referencedNamespaces: Set<String>

    /// Compiles rules. If nonInteractive, invalid rules are skipped with warnings logged.
    /// Otherwise, errors are thrown.
    init(rules: [Rule], pluginId: String? = nil, nonInteractive: Bool = false, logger: Logger) throws {
        var compiled: [CompiledRule] = []
        for (index, rule) in rules.enumerated() {
            let isUnconditional = rule.match == nil
            let namespace: String
            let field: String
            let matcher: (any TagMatcher & Sendable)?
            let not: Bool

            if let match = rule.match {
                // Parse field: split on first ":"
                let split = Self.splitField(match.field, pluginId: pluginId)
                namespace = split.namespace
                field = split.field

                // Reject unresolved self: prefix when no pluginId was provided
                if namespace == "self" {
                    let compError = RuleCompilationError.unresolvedSelf(ruleIndex: index)
                    if nonInteractive {
                        logger.warning("\(compError.localizedDescription) — skipping rule")
                        continue
                    }
                    throw compError
                }

                // Compile match pattern
                do {
                    matcher = try TagMatcherFactory.build(from: match.pattern)
                } catch {
                    let compError = RuleCompilationError.invalidRegex(
                        ruleIndex: index, pattern: match.pattern, underlying: error
                    )
                    if nonInteractive {
                        logger.warning("\(compError.localizedDescription) — skipping rule")
                        continue
                    }
                    throw compError
                }

                not = match.not ?? false
            } else {
                namespace = ""
                field = ""
                matcher = nil
                not = false
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
                unconditional: isUnconditional,
                namespace: namespace,
                field: field,
                matcher: matcher,
                not: not,
                emitActions: emitActions,
                writeActions: writeActions
            ))
        }
        // Collect foreign namespaces referenced by compiled rules
        let reserved: Set<String> = {
            var set: Set<String> = ["", "read", "self", ReservedName.skip]
            if let pluginId { set.insert(pluginId) }
            return set
        }()
        var namespaces = Set<String>()
        for rule in compiled {
            if !reserved.contains(rule.namespace) {
                namespaces.insert(rule.namespace)
            }
            for action in rule.emitActions + rule.writeActions {
                if case let .clone(_, sourceNamespace, _) = action,
                   !reserved.contains(sourceNamespace)
                {
                    namespaces.insert(sourceNamespace)
                }
            }
        }
        referencedNamespaces = namespaces

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
            return .remove(field: field, matchers: matchers, not: config.not ?? false)

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
            return .removeField(field: field, not: config.not ?? false)

        case "writeBack":
            return .writeBack

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

    /// Evaluate rules against resolved state, returning the updated namespace.
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
            let shouldApply: Bool

            if rule.unconditional {
                shouldApply = true
            } else {
                // Resolve the match field value
                let value: JSONValue?
                if rule.namespace == "read", let buffer = metadataBuffer, let image = imageName {
                    let fileMetadata = await buffer.load(image: image)
                    value = fileMetadata[rule.field]
                } else if rule.namespace.isEmpty, rule.field == "skip", let image = imageName {
                    value = Self.resolveSkipField(image: image, state: state)
                } else {
                    value = state[rule.namespace]?[rule.field]
                }

                guard let value else { continue }

                shouldApply = Self.resolveMatch(
                    rule: rule,
                    state: state,
                    metadataBuffer: metadataBuffer,
                    imageName: imageName,
                    resolvedValue: value
                )
            }

            if shouldApply {
                // Emit actions first (modify plugin namespace)
                var didSkip = false
                for action in rule.emitActions {
                    if case .writeBack = action {
                        continue
                    }
                    if case .skip = action {
                        if let store = stateStore, let image = imageName, let plugin = pluginId {
                            let record = JSONValue.object(["file": .string(image), "plugin": .string(plugin)])
                            await store.appendSkipRecord(image: image, record: record)
                        }
                        didSkip = true
                        break
                    }
                    if case let .clone(field, sourceNamespace, sourceField) = action {
                        if sourceNamespace == "read", let buffer = metadataBuffer, let image = imageName {
                            let fileMetadata = await buffer.load(image: image)
                            if field == "*" {
                                for (key, val) in fileMetadata {
                                    Self.mergeClonedValue(val, into: &working, forKey: key)
                                }
                            } else if let sourceField, let val = fileMetadata[sourceField] {
                                Self.mergeClonedValue(val, into: &working, forKey: field)
                            }
                        } else if field == "*" {
                            if let namespaceData = state[sourceNamespace] {
                                for (key, val) in namespaceData {
                                    Self.mergeClonedValue(val, into: &working, forKey: key)
                                }
                            }
                        } else if let sourceField, let val = state[sourceNamespace]?[sourceField] {
                            Self.mergeClonedValue(val, into: &working, forKey: field)
                        }
                        continue
                    }
                    Self.autoCloneIfNeeded(action: action, working: &working, state: state, namespace: rule.namespace)
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

    /// Resolve the match field value for a conditional rule and determine
    /// whether the rule's matcher matches the resolved value.
    /// Returns nil when the field value cannot be resolved (rule should be skipped).
    private static func resolveMatch(
        rule: CompiledRule,
        state _: [String: [String: JSONValue]],
        metadataBuffer _: MetadataBuffer?,
        imageName _: String?,
        resolvedValue: JSONValue
    ) -> Bool {
        let matcher = rule.matcher!
        let matched: Bool = switch resolvedValue {
        case let .string(str):
            matcher.matches(str)
        case let .array(arr):
            arr.contains { element in
                if case let .string(str) = element {
                    return matcher.matches(str)
                }
                return false
            }
        default:
            false
        }
        return rule.not ? !matched : matched
    }

    /// If a remove or replace action targets a field not yet in working,
    /// seed it from the match rule's source namespace so the action has data to operate on.
    static func autoCloneIfNeeded(
        action: EmitAction,
        working: inout [String: JSONValue],
        state: [String: [String: JSONValue]],
        namespace: String
    ) {
        switch action {
        case let .remove(field, _, _), let .replace(field, _):
            if working[field] == nil,
               let source = state[namespace]?[field]
            {
                working[field] = source
            }
        default:
            break
        }
    }

    static func applyAction(_ action: EmitAction, to working: inout [String: JSONValue]) {
        switch action {
        case .skip:
            break

        case let .add(field, values):
            var existing = extractStrings(from: working[field])
            for val in values where !existing.contains(val) {
                existing.append(val)
            }
            working[field] = .array(existing.map { .string($0) })

        case let .remove(field, matchers, not):
            var existing = extractStrings(from: working[field])
            if not {
                existing = existing.filter { value in
                    matchers.contains { $0.matches(value) }
                }
            } else {
                existing.removeAll { value in
                    matchers.contains { $0.matches(value) }
                }
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

        case let .removeField(field, not):
            if not {
                let kept = working[field]
                working.removeAll()
                if let kept { working[field] = kept }
            } else if field == "*" {
                working.removeAll()
            } else {
                working.removeValue(forKey: field)
            }

        case .clone, .writeBack:
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

    /// Merges `source` into `working[key]`, appending unique array values. Non-array values are replaced.
    private static func mergeClonedValue(_ source: JSONValue, into working: inout [String: JSONValue], forKey key: String) {
        let incoming = extractStrings(from: source)
        if !incoming.isEmpty, working[key] != nil {
            var existing = extractStrings(from: working[key])
            for val in incoming where !existing.contains(val) {
                existing.append(val)
            }
            working[key] = .array(existing.map { .string($0) })
        } else {
            working[key] = source
        }
    }

    /// Returns the image name as a `.string` value if it is present in the skip records, otherwise nil.
    private static func resolveSkipField(image: String, state: [String: [String: JSONValue]]) -> JSONValue? {
        guard case let .array(records) = state[ReservedName.skip]?[ReservedName.skipRecords] else {
            return nil
        }
        let isSkipped = records.contains { record in
            if case let .object(dict) = record, case let .string(file) = dict["file"] {
                return file == image
            }
            return false
        }
        return isSkipped ? .string(image) : nil
    }

    private static func splitField(_ field: String, pluginId: String? = nil) -> (namespace: String, field: String) {
        guard let colonIndex = field.firstIndex(of: ":") else {
            // Bare field name (no colon)
            if field == "skip" {
                return ("", field)
            }
            if let pluginId {
                return (pluginId, field)
            }
            return ("", field)
        }
        let namespace = String(field[field.startIndex ..< colonIndex])
        let fieldName = String(field[field.index(after: colonIndex)...])
        if namespace == "self" {
            if let pluginId {
                return (pluginId, fieldName)
            }
            return ("self", fieldName)
        }
        return (namespace, fieldName)
    }
}
