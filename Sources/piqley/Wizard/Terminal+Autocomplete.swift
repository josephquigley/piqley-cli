import Foundation

// MARK: - Autocomplete Helpers

extension RawTerminal {
    /// Computes the autocomplete query and, when a triggerPrefix is active, the
    /// string range that will be replaced by a completed template expression.
    func resolveAutocompleteQuery(
        input: String, cursorPos: Int, triggerPrefix: String?
    ) -> (query: String, templateInsertRange: Range<String.Index>?) {
        guard let trigger = triggerPrefix else {
            return (input.lowercased(), nil)
        }
        let beforeCursor = String(input.prefix(cursorPos))
        guard let lastOpen = beforeCursor.range(of: trigger, options: .backwards) else {
            return ("", nil)
        }
        let afterOpen = String(beforeCursor[lastOpen.upperBound...])
        guard !afterOpen.contains("}}") else {
            return ("", nil)
        }
        let rangeEnd = input.index(input.startIndex, offsetBy: cursorPos)
        return (afterOpen.lowercased(), lastOpen.lowerBound ..< rangeEnd)
    }

    /// Applies a tab completion to `input`/`cursorPos`. When a `templateInsertRange`
    /// is provided the completion is wrapped in `triggerPrefix…}}` at that range;
    /// otherwise the whole input is replaced.
    func applyTabCompletion(
        completionValue: String,
        triggerPrefix: String?,
        templateInsertRange: Range<String.Index>?,
        input: inout String,
        cursorPos: inout Int
    ) {
        if let trigger = triggerPrefix, let range = templateInsertRange {
            let closing = "}}"
            let replacement = "\(trigger)\(completionValue)\(closing)"
            let beforeTemplate = String(input[input.startIndex ..< range.lowerBound])
            let afterCursor = String(input[input.index(input.startIndex, offsetBy: cursorPos)...])
            input = beforeTemplate + replacement + afterCursor
            cursorPos = beforeTemplate.count + replacement.count
        } else {
            input = completionValue
            cursorPos = input.count
        }
    }
}
