# Rule Emit Template Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `{{namespace:field}}` template resolution to `add` action values in declarative metadata rules, extract a shared TemplateResolver from PluginRunner, and add context-sensitive `{{` autocomplete to the rule value editor.

**Architecture:** Extract the template parsing/resolution logic from `PluginRunner+Templates.swift` into a standalone `TemplateResolver` struct. Wire it into `RuleEvaluator.evaluate()` for `add` actions. Modify `promptWithAutocomplete` to support a `triggerPrefix` parameter for context-sensitive completions, and use it in the rule value editor.

**Tech Stack:** Swift, PiqleyCore, Swift Testing

---

### Task 1: Extract TemplateResolver from PluginRunner

**Files:**
- Create: `Sources/piqley/State/TemplateResolver.swift`
- Modify: `Sources/piqley/Plugins/PluginRunner+Templates.swift`

- [ ] **Step 1: Write failing tests for TemplateResolver**

Create `Tests/piqleyTests/TemplateResolverTests.swift`:

```swift
import Testing
import Foundation
import Logging
import PiqleyCore
@testable import piqley

@Suite("TemplateResolver")
struct TemplateResolverTests {
    private let logger = Logger(label: "test.template-resolver")
    private let resolver = TemplateResolver()

    @Test("resolves simple field reference")
    func simpleField() async {
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:CameraMake": .string("Canon")]
        ]
        let result = await resolver.resolve(
            "{{original:EXIF:CameraMake}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "Canon")
    }

    @Test("resolves self namespace to pluginId")
    func selfNamespace() async {
        let state: [String: [String: JSONValue]] = [
            "com.test.plugin": ["tags": .array([.string("landscape"), .string("sunset")])]
        ]
        let result = await resolver.resolve(
            "{{self:tags}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: "com.test.plugin", logger: logger
        )
        #expect(result == "landscape,sunset")
    }

    @Test("resolves multiple templates in one string")
    func multipleTemplates() async {
        let state: [String: [String: JSONValue]] = [
            "original": [
                "EXIF:CameraMake": .string("Canon"),
                "EXIF:LensModel": .string("RF 24-70mm")
            ]
        ]
        let result = await resolver.resolve(
            "{{original:EXIF:CameraMake}} with {{original:EXIF:LensModel}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "Canon with RF 24-70mm")
    }

    @Test("missing field resolves to empty string")
    func missingField() async {
        let result = await resolver.resolve(
            "{{original:EXIF:Missing}}",
            state: [:], metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "")
    }

    @Test("literal string without templates passes through unchanged")
    func literalPassthrough() async {
        let result = await resolver.resolve(
            "https://example.com",
            state: [:], metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "https://example.com")
    }

    @Test("number values resolve as integers when whole")
    func numberResolution() async {
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:FocalLength": .number(50)]
        ]
        let result = await resolver.resolve(
            "{{original:EXIF:FocalLength}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "50")
    }

    @Test("bool values resolve correctly")
    func boolResolution() async {
        let state: [String: [String: JSONValue]] = [
            "original": ["EXIF:Flash": .bool(true)]
        ]
        let result = await resolver.resolve(
            "{{original:EXIF:Flash}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "true")
    }

    @Test("array values join with commas")
    func arrayJoinsWithCommas() async {
        let state: [String: [String: JSONValue]] = [
            "original": ["IPTC:Keywords": .array([.string("landscape"), .string("sunset")])]
        ]
        let result = await resolver.resolve(
            "{{original:IPTC:Keywords}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "landscape,sunset")
    }

    @Test("bare colon-delimited field falls back to plugin namespace")
    func bareFieldFallback() async {
        let state: [String: [String: JSONValue]] = [
            "com.test.plugin": ["IPTC:Keywords": .array([.string("landscape")])]
        ]
        let result = await resolver.resolve(
            "{{IPTC:Keywords}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: "com.test.plugin", logger: logger
        )
        #expect(result == "landscape")
    }

    @Test("read namespace resolves from MetadataBuffer")
    func readNamespace() async {
        let buffer = MetadataBuffer(preloaded: [
            "test.jpg": ["EXIF:Make": .string("Nikon")]
        ])
        let result = await resolver.resolve(
            "{{read:EXIF:Make}}",
            state: [:], metadataBuffer: buffer, imageName: "test.jpg", pluginId: nil, logger: logger
        )
        #expect(result == "Nikon")
    }

    @Test("mixed literal and template text")
    func mixedLiteralAndTemplate() async {
        let state: [String: [String: JSONValue]] = [
            "photo.quigs.datetools": ["365_offset": .string("42")]
        ]
        let result = await resolver.resolve(
            "365 Project #{{photo.quigs.datetools:365_offset}}",
            state: state, metadataBuffer: nil, imageName: nil, pluginId: nil, logger: logger
        )
        #expect(result == "365 Project #42")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TemplateResolverTests 2>&1 | head -40`
Expected: Compilation error, `TemplateResolver` not defined.

- [ ] **Step 3: Create TemplateResolver**

Create `Sources/piqley/State/TemplateResolver.swift`:

```swift
import Foundation
import Logging
import PiqleyCore

struct TemplateResolver: Sendable {
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

    func resolve(
        _ template: String,
        state: [String: [String: JSONValue]],
        metadataBuffer: MetadataBuffer?,
        imageName: String?,
        pluginId: String?,
        logger: Logger
    ) async -> String {
        var result = template
        while let openRange = result.range(of: "{{"),
              let closeRange = result.range(of: "}}", range: openRange.upperBound ..< result.endIndex)
        {
            let reference = String(result[openRange.upperBound ..< closeRange.lowerBound])
            let resolved = await resolveFieldReference(
                reference, state: state, metadataBuffer: metadataBuffer,
                imageName: imageName, pluginId: pluginId, logger: logger
            )
            result.replaceSubrange(openRange.lowerBound ..< closeRange.upperBound, with: resolved)
        }
        return result
    }

    private func resolveFieldReference(
        _ reference: String,
        state: [String: [String: JSONValue]],
        metadataBuffer: MetadataBuffer?,
        imageName: String?,
        pluginId: String?,
        logger: Logger
    ) async -> String {
        guard let colonIndex = reference.firstIndex(of: ":") else {
            logger.warning("Invalid template reference '\(reference)' — missing ':'")
            return ""
        }
        var namespace = String(reference[reference.startIndex ..< colonIndex])
        let field = String(reference[reference.index(after: colonIndex)...])

        if namespace == "self" {
            guard let pluginId else {
                logger.warning("Template reference '{{\(reference)}}' uses 'self' but no pluginId provided")
                return ""
            }
            namespace = pluginId
        }

        if namespace == "read", let buffer = metadataBuffer, let imageName {
            let fileMetadata = await buffer.load(image: imageName)
            if let value = fileMetadata[field] {
                return jsonValueToString(value)
            }
            logger.warning("Template '{{\(reference)}}' resolved to empty — field not found in file metadata")
            return ""
        }

        if let namespaceState = state[namespace], let value = namespaceState[field] {
            return jsonValueToString(value)
        }

        // Fallback: colon-delimited field name in plugin's own namespace
        if state[namespace] == nil, let pluginId {
            if let value = state[pluginId]?[reference] {
                return jsonValueToString(value)
            }
        }

        logger.warning("Template '{{\(reference)}}' resolved to empty — field not found in state")
        return ""
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TemplateResolverTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Refactor PluginRunner+Templates to delegate to TemplateResolver**

Modify `Sources/piqley/Plugins/PluginRunner+Templates.swift`. Replace the body of `resolveTemplate` and `resolveFieldReference` to delegate to `TemplateResolver`, and remove the duplicated `jsonValueToString` (it moves to the resolver). Keep the `PluginRunner` API surface unchanged:

```swift
import Foundation
import PiqleyCore

extension PluginRunner {
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
        let resolver = TemplateResolver()
        return await resolver.resolve(
            template,
            state: imageState ?? [:],
            metadataBuffer: metadataBuffer,
            imageName: imageName,
            pluginId: plugin.identifier,
            logger: logger
        )
    }
}
```

- [ ] **Step 6: Run existing PluginRunner environment tests to verify no regression**

Run: `swift test --filter PluginRunnerEnvironmentTests 2>&1 | tail -20`
Expected: All existing tests pass.

- [ ] **Step 7: Commit**

Message: `refactor: extract TemplateResolver from PluginRunner for shared template resolution`

---

### Task 2: Wire TemplateResolver into RuleEvaluator for add actions

**Files:**
- Modify: `Sources/piqley/State/RuleEvaluator.swift`
- Modify: `Tests/piqleyTests/RuleEvaluatorTests.swift`

- [ ] **Step 1: Write failing tests for template resolution in add actions**

Append to `Tests/piqleyTests/RuleEvaluatorTests.swift`:

```swift
// MARK: - Template resolution in add values

@Test("add value with template resolves from state")
func addWithTemplate() async throws {
    let rule = Rule(
        match: MatchConfig(field: "original:TIFF:Model", pattern: "Sony"),
        emit: [EmitConfig(
            action: "add", field: "title",
            values: ["Shot on {{original:TIFF:Model}}"],
            replacements: nil, source: nil
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let result = await evaluator.evaluate(
        state: ["original": ["TIFF:Model": .string("Sony A7R IV")]]
    )
    #expect(result.namespace["title"] == .array([.string("Shot on Sony A7R IV")]))
}

@Test("add value with template referencing another plugin namespace")
func addWithCrossNamespaceTemplate() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(
            action: "add", field: "title",
            values: ["365 Project #{{photo.quigs.datetools:365_offset}}"],
            replacements: nil, source: nil
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let result = await evaluator.evaluate(
        state: ["photo.quigs.datetools": ["365_offset": .string("42")]]
    )
    #expect(result.namespace["title"] == .array([.string("365 Project #42")]))
}

@Test("add value with missing template field resolves to empty")
func addWithMissingTemplateField() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(
            action: "add", field: "title",
            values: ["Project #{{photo.quigs.datetools:365_offset}}"],
            replacements: nil, source: nil
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let result = await evaluator.evaluate(state: [:])
    #expect(result.namespace["title"] == .array([.string("Project #")]))
}

@Test("add value without templates is unchanged")
func addWithoutTemplate() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(
            action: "add", field: "keywords",
            values: ["landscape"],
            replacements: nil, source: nil
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let result = await evaluator.evaluate(state: [:])
    #expect(result.namespace["keywords"] == .array([.string("landscape")]))
}

@Test("add value with template resolving array joins with commas")
func addWithArrayTemplate() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(
            action: "add", field: "summary",
            values: ["Tags: {{original:IPTC:Keywords}}"],
            replacements: nil, source: nil
        )]
    )
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let result = await evaluator.evaluate(
        state: ["original": ["IPTC:Keywords": .array([.string("landscape"), .string("sunset")])]]
    )
    #expect(result.namespace["summary"] == .array([.string("Tags: landscape,sunset")]))
}

@Test("add value with read namespace template")
func addWithReadNamespaceTemplate() async throws {
    let rule = Rule(
        match: nil,
        emit: [EmitConfig(
            action: "add", field: "camera",
            values: ["{{read:EXIF:Make}}"],
            replacements: nil, source: nil
        )]
    )
    let buffer = MetadataBuffer(preloaded: [
        "test.jpg": ["EXIF:Make": .string("Nikon")]
    ])
    let evaluator = try RuleEvaluator(rules: [rule], logger: logger)
    let result = await evaluator.evaluate(
        state: [:], metadataBuffer: buffer, imageName: "test.jpg"
    )
    #expect(result.namespace["camera"] == .array([.string("Nikon")]))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RuleEvaluatorTests/addWithTemplate 2>&1 | tail -20`
Expected: FAIL. The template string `"Shot on {{original:TIFF:Model}}"` is added literally without resolution.

- [ ] **Step 3: Add template resolution to the evaluate loop**

In `Sources/piqley/State/RuleEvaluator.swift`, add a `private static let templateResolver = TemplateResolver()` property to `RuleEvaluator`, and modify the emit action loop inside `evaluate()` to resolve templates for `.add` actions.

Replace the block at line 277 (`for action in rule.emitActions`) with:

```swift
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

    // Resolve templates in add values
    let resolvedAction: EmitAction
    if case let .add(field, values) = action,
       values.contains(where: { $0.contains("{{") })
    {
        var resolvedValues: [String] = []
        for value in values {
            if value.contains("{{") {
                let resolved = await Self.templateResolver.resolve(
                    value, state: state, metadataBuffer: metadataBuffer,
                    imageName: imageName, pluginId: pluginId, logger: logger
                )
                resolvedValues.append(resolved)
            } else {
                resolvedValues.append(value)
            }
        }
        resolvedAction = .add(field: field, values: resolvedValues)
    } else {
        resolvedAction = action
    }

    Self.autoCloneIfNeeded(action: resolvedAction, working: &working, state: state, namespace: rule.namespace)
    Self.applyAction(resolvedAction, to: &working)
}
```

Also modify `RuleEvaluator` to store what's needed for template resolution:

1. Add stored properties to the struct (after `referencedNamespaces`):

```swift
private static let templateResolver = TemplateResolver()
private let logger: Logger
```

2. In the `init`, store the logger before the compilation loop:

```swift
self.logger = logger
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `swift test --filter RuleEvaluatorTests 2>&1 | tail -30`
Expected: All tests pass, including the new template tests.

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 6: Commit**

Message: `feat: resolve {{namespace:field}} templates in rule add action values`

---

### Task 3: Add triggerPrefix support to promptWithAutocomplete

**Files:**
- Modify: `Sources/piqley/Wizard/Terminal.swift`

- [ ] **Step 1: Add the triggerPrefix parameter to promptWithAutocomplete**

In `Sources/piqley/Wizard/Terminal.swift`, modify the `promptWithAutocomplete` method signature to add the new parameter:

```swift
func promptWithAutocomplete(
    title: String, hint: String, completions: [String],
    browsableList: [String]? = nil, defaultValue: String? = nil,
    allowEmpty: Bool = false, insertCompletions: [String]? = nil,
    noMatchHint: String? = nil, subtitleNote: String? = nil,
    triggerPrefix: String? = nil
) -> String? {
```

- [ ] **Step 2: Modify the matching logic to be context-sensitive**

Inside `promptWithAutocomplete`, replace the matching logic (around line 356) with:

```swift
// Determine query for matching: if triggerPrefix is set, only match
// when cursor is inside an open template expression
let query: String
let templateInsertRange: Range<String.Index>?
if let trigger = triggerPrefix {
    let beforeCursor = String(input.prefix(cursorPos))
    if let lastOpen = beforeCursor.range(of: trigger, options: .backwards) {
        let afterOpen = String(beforeCursor[lastOpen.upperBound...])
        // Only active if there's no closing "}}" after the opening "{{"
        if !afterOpen.contains("}}") {
            query = afterOpen.lowercased()
            templateInsertRange = lastOpen.lowerBound ..< input.index(input.startIndex, offsetBy: cursorPos)
        } else {
            query = ""
            templateInsertRange = nil
        }
    } else {
        query = ""
        templateInsertRange = nil
    }
} else {
    query = input.lowercased()
    templateInsertRange = nil
}
let matchedIndices: [Int] = query.isEmpty && triggerPrefix != nil
    ? []
    : query.isEmpty
        ? Array(completions.indices)
        : completions.enumerated().compactMap { idx, item in
            item.lowercased().contains(query) ? idx : nil
        }
let matches = matchedIndices.map { completions[$0] }
```

- [ ] **Step 3: Modify Tab completion to insert template with braces**

In the `.tab` case, when `triggerPrefix` is set, insert `{{completion}}` at the template position instead of replacing the whole input. Replace the tab handling block:

```swift
case .tab:
    guard !matchedIndices.isEmpty else { continue }
    let selectedIdx: Int
    if let arrow = arrowIndex {
        selectedIdx = matchedIndices[arrow]
        tabCycleIndex = arrow + 1
        lastTabQuery = query
        arrowIndex = nil
        scrollOffset = 0
    } else {
        if query != lastTabQuery { tabCycleIndex = 0; lastTabQuery = query }
        selectedIdx = matchedIndices[tabCycleIndex % matchedIndices.count]
        tabCycleIndex += 1
    }

    let completionValue = insertCompletions?[selectedIdx] ?? completions[selectedIdx]

    if let trigger = triggerPrefix, let range = templateInsertRange {
        // Insert {{completion}} at the template position
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
```

Note: The `templateInsertRange` variable needs to be accessible in the tab handler. Since it's computed at the top of the loop and the tab case is in the same loop iteration, it's already in scope.

- [ ] **Step 4: Verify existing callers are unaffected (triggerPrefix defaults to nil)**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds. All existing callers pass nil for triggerPrefix, preserving current behavior.

- [ ] **Step 5: Commit**

Message: `feat: add triggerPrefix parameter to promptWithAutocomplete for context-sensitive completions`

---

### Task 4: Wire autocomplete into rule value editor for add actions

**Files:**
- Modify: `Sources/piqley/Wizard/RulesWizard+BuildRule.swift`
- Modify: `Sources/piqley/Wizard/RulesWizard+EditAction.swift`

- [ ] **Step 1: Update the value hint for add actions**

In `Sources/piqley/Wizard/RulesWizard+BuildRule.swift`, add a constant for the template-aware hint. Add this near the top of the extension or as a private property:

```swift
private static let addValueHint = "e.g. sony, regex:.*pattern.*, or use {{field}} for dynamic values"
```

- [ ] **Step 2: Switch the add value loop in promptForEmitConfig to use promptWithAutocomplete**

In `Sources/piqley/Wizard/RulesWizard+BuildRule.swift`, replace the add value input loop (lines 179-199) with:

```swift
case "add":
    let qualifiedCompletions = buildQualifiedFieldCompletions()
    var values: [String] = []
    while true {
        let ordinal = values.isEmpty ? "first" : "next"
        let hint = values.isEmpty
            ? Self.addValueHint
            : "Enter another value, or press Enter to finish"
        guard let value = terminal.promptWithAutocomplete(
            title: "Enter \(ordinal) value",
            hint: hint,
            completions: qualifiedCompletions,
            allowEmpty: !values.isEmpty,
            triggerPrefix: "{{"
        ) else {
            if values.isEmpty { return nil }
            break
        }
        if value.isEmpty { break }
        values.append(value)
    }
    if values.isEmpty { return nil }
    return EmitConfig(action: action, field: field, values: values, replacements: nil, source: nil)

case "remove":
    var values: [String] = []
    while true {
        let ordinal = values.isEmpty ? "first" : "next"
        let hint = values.isEmpty
            ? "e.g. sony  or  regex:.*\\d+mm.*"
            : "Enter another value, or press Enter to finish"
        guard let value = terminal.promptForInput(
            title: "Enter \(ordinal) value",
            hint: hint,
            allowEmpty: !values.isEmpty
        ) else {
            if values.isEmpty { return nil }
            break
        }
        if value.isEmpty { break }
        values.append(value)
    }
    if values.isEmpty { return nil }
    return EmitConfig(action: action, field: field, values: values, replacements: nil, source: nil)
```

- [ ] **Step 3: Update handleAddValue in RulesWizard+EditAction.swift**

In `Sources/piqley/Wizard/RulesWizard+EditAction.swift`, replace the `handleAddValue` method (lines 219-238) with:

```swift
private func handleAddValue(state: inout EditActionState) {
    if state.action == "replace" {
        if let pat = terminal.promptForInput(
            title: "Replacement pattern",
            hint: "Pattern to match in values"
        ), let repStr = terminal.promptForInput(
            title: "Replacement string",
            hint: "What to replace with (use $1, $2 for capture groups)"
        ) {
            state.replacements.append(Replacement(pattern: pat, replacement: repStr))
        }
    } else if state.action == "add" {
        let qualifiedCompletions = buildQualifiedFieldCompletions()
        if let val = terminal.promptWithAutocomplete(
            title: "Enter value",
            hint: "e.g. sony, regex:.*pattern.*, or use {{field}} for dynamic values",
            completions: qualifiedCompletions,
            triggerPrefix: "{{"
        ) {
            state.values.append(val)
        }
    } else {
        if let val = terminal.promptForInput(
            title: "Enter value",
            hint: "e.g. sony  or  regex:.*\\d+mm.*"
        ) {
            state.values.append(val)
        }
    }
}
```

- [ ] **Step 4: Update the edit-existing-value case for add actions**

In `Sources/piqley/Wizard/RulesWizard+EditAction.swift`, replace the `.value(idx)` case (lines 110-117) with:

```swift
case let .value(idx):
    if state.action == "add" {
        let qualifiedCompletions = buildQualifiedFieldCompletions()
        if let newVal = terminal.promptWithAutocomplete(
            title: "Edit value",
            hint: "e.g. sony, regex:.*pattern.*, or use {{field}} for dynamic values",
            completions: qualifiedCompletions,
            defaultValue: state.values[idx],
            triggerPrefix: "{{"
        ) {
            state.values[idx] = newVal
        }
    } else if let newVal = terminal.promptForInput(
        title: "Edit value",
        hint: "Enter new value",
        defaultValue: state.values[idx]
    ) {
        state.values[idx] = newVal
    }
```

- [ ] **Step 5: Update handleActionTypeSelection for add case**

In `Sources/piqley/Wizard/RulesWizard+EditAction.swift`, replace the `"add"` case inside `handleActionTypeSelection` (lines 185-191) with:

```swift
case "add":
    let qualifiedCompletions = buildQualifiedFieldCompletions()
    if let val = terminal.promptWithAutocomplete(
        title: "Enter first value",
        hint: "e.g. sony, regex:.*pattern.*, or use {{field}} for dynamic values",
        completions: qualifiedCompletions,
        triggerPrefix: "{{"
    ) {
        state.values.append(val)
    }
case "remove":
    if let val = terminal.promptForInput(
        title: "Enter first value",
        hint: "e.g. sony  or  regex:.*\\d+mm.*"
    ) {
        state.values.append(val)
    }
```

- [ ] **Step 6: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 7: Run full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 8: Commit**

Message: `feat: add {{field}} template autocomplete to rule value editor for add actions`

---

### Task 5: Add CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add entry under Unreleased**

Add to the `Added` section under `[Unreleased]`:

```markdown
- Rule `add` action values now support `{{namespace:field}}` template syntax to reference other fields dynamically (e.g. `365 Project #{{photo.quigs.datetools:365_offset}}`)
- Rule value editor shows field autocomplete when typing `{{` in add action values
```

- [ ] **Step 2: Commit**

Message: `docs: add changelog entries for rule emit template resolution`
