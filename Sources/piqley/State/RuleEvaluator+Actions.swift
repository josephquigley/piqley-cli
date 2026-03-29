import PiqleyCore

extension RuleEvaluator {
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

    static func extractStrings(from value: JSONValue?) -> [String] {
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
    static func mergeClonedValue(_ source: JSONValue, into working: inout [String: JSONValue], forKey key: String) {
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
}
