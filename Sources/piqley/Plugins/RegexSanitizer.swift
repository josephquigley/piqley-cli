import Foundation
import PiqleyCore

/// Detects and fixes double-escaped backslashes in regex patterns.
///
/// When a regex pattern like `\d` is double-escaped, it becomes `\\d` in memory
/// (which is `\\\\d` in JSON). The regex engine then sees a literal backslash
/// followed by `d` instead of the digit character class.
///
/// This sanitizer detects the pattern and collapses `\\` back to `\` within
/// regex-prefixed strings.
enum RegexSanitizer {
    /// Sanitize a single pattern string.
    /// Returns the (possibly fixed) string and whether a fix was applied.
    static func sanitize(_ value: String) -> (String, Bool) {
        guard value.hasPrefix(PatternPrefix.regex) else {
            return (value, false)
        }

        let regexBody = String(value.dropFirst(PatternPrefix.regex.count))

        // Detect double-escaped backslashes: `\\` followed by a character
        // that is a valid regex escape (so we don't collapse literal `\\` pairs
        // that are intentional).
        guard regexBody.contains("\\\\") else {
            return (value, false)
        }

        // Collapse all `\\` into `\` within the regex body.
        let fixed = regexBody.replacingOccurrences(of: "\\\\", with: "\\")
        return ("\(PatternPrefix.regex)\(fixed)", true)
    }

    /// Sanitize all regex patterns in a StageConfig.
    /// Returns the (possibly fixed) config and whether any fixes were applied.
    static func sanitizeStageConfig(_ config: StageConfig) -> (StageConfig, Bool) {
        var didFix = false

        let preRules = config.preRules.map { rules in
            rules.map { rule in
                let (fixedRule, ruleFix) = sanitizeRule(rule)
                if ruleFix { didFix = true }
                return fixedRule
            }
        }

        let postRules = config.postRules.map { rules in
            rules.map { rule in
                let (fixedRule, ruleFix) = sanitizeRule(rule)
                if ruleFix { didFix = true }
                return fixedRule
            }
        }

        let result = StageConfig(preRules: preRules, binary: config.binary, postRules: postRules)
        return (result, didFix)
    }

    // MARK: - Private

    private static func sanitizeRule(_ rule: Rule) -> (Rule, Bool) {
        var didFix = false

        // Sanitize match pattern
        let (fixedPattern, matchFix) = sanitize(rule.match.pattern)
        if matchFix { didFix = true }
        let fixedMatch = MatchConfig(field: rule.match.field, pattern: fixedPattern, not: rule.match.not)

        // Sanitize emit configs
        let fixedEmit = rule.emit.map { emit -> EmitConfig in
            let (fixed, fix) = sanitizeEmitConfig(emit)
            if fix { didFix = true }
            return fixed
        }

        // Sanitize write configs
        let fixedWrite = rule.write.map { emit -> EmitConfig in
            let (fixed, fix) = sanitizeEmitConfig(emit)
            if fix { didFix = true }
            return fixed
        }

        return (Rule(match: fixedMatch, emit: fixedEmit, write: fixedWrite), didFix)
    }

    private static func sanitizeEmitConfig(_ emit: EmitConfig) -> (EmitConfig, Bool) {
        var didFix = false

        // Sanitize values
        let fixedValues = emit.values.map { values in
            values.map { value -> String in
                let (fixed, fix) = sanitize(value)
                if fix { didFix = true }
                return fixed
            }
        }

        // Sanitize replacement patterns
        let fixedReplacements = emit.replacements.map { replacements in
            replacements.map { rep -> Replacement in
                let (fixedPattern, fix) = sanitize(rep.pattern)
                if fix { didFix = true }
                return Replacement(pattern: fixedPattern, replacement: rep.replacement)
            }
        }

        let result = EmitConfig(
            action: emit.action, field: emit.field,
            values: fixedValues, replacements: fixedReplacements,
            source: emit.source, not: emit.not
        )
        return (result, didFix)
    }
}
