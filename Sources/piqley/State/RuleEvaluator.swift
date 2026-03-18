import Foundation
import Logging
import PiqleyCore

struct CompiledRule: Sendable {
    let hook: String
    let namespace: String
    let field: String
    let matcher: any TagMatcher & Sendable
    let emitField: String
    let emitValues: [String]
}

enum RuleCompilationError: Error, LocalizedError {
    case invalidRegex(ruleIndex: Int, pattern: String, underlying: Error)
    case unknownHook(ruleIndex: Int, hook: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRegex(ruleIndex, pattern, err):
            "Rule \(ruleIndex): invalid regex '\(pattern)': \(err.localizedDescription)"
        case let .unknownHook(ruleIndex, hook):
            "Rule \(ruleIndex): unknown hook '\(hook)'"
        }
    }
}

struct RuleEvaluator: Sendable {
    let compiledRules: [CompiledRule]

    /// Compiles rules. If nonInteractive, invalid rules are skipped with warnings logged.
    /// Otherwise, errors are thrown.
    init(rules: [Rule], nonInteractive: Bool = false, logger: Logger) throws {
        var compiled: [CompiledRule] = []
        for (index, rule) in rules.enumerated() {
            let hook = rule.match.hook ?? Hook.preProcess.rawValue

            // Validate hook
            guard Hook.canonicalOrder.map(\.rawValue).contains(hook) else {
                let error = RuleCompilationError.unknownHook(ruleIndex: index, hook: hook)
                if nonInteractive {
                    logger.warning("\(error.localizedDescription) — skipping rule")
                    continue
                }
                throw error
            }

            // Parse field: split on first ":"
            let (namespace, field) = Self.splitField(rule.match.field)

            // Compile pattern
            do {
                let matcher = try TagMatcherFactory.build(from: rule.match.pattern)
                compiled.append(CompiledRule(
                    hook: hook,
                    namespace: namespace,
                    field: field,
                    matcher: matcher,
                    emitField: rule.emit.field ?? "keywords",
                    emitValues: rule.emit.values
                ))
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
        }
        compiledRules = compiled
    }

    /// Evaluate rules for a given hook against resolved state.
    /// state is [namespace: [field: JSONValue]]
    func evaluate(
        hook: String,
        state: [String: [String: JSONValue]]
    ) -> [String: JSONValue] {
        var results: [String: [String]] = [:]

        for rule in compiledRules where rule.hook == hook {
            guard let namespaceData = state[rule.namespace],
                  let value = namespaceData[rule.field]
            else {
                continue
            }

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
                var existing = results[rule.emitField] ?? []
                for val in rule.emitValues where !existing.contains(val) {
                    existing.append(val)
                }
                results[rule.emitField] = existing
            }
        }

        // Convert to [String: JSONValue]
        var output: [String: JSONValue] = [:]
        for (field, values) in results {
            output[field] = .array(values.map { .string($0) })
        }
        return output
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
