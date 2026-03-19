# Rule Editor Wizard Design

## Overview

An interactive TUI wizard for creating, editing, removing, and reordering declarative metadata rules for installed plugins. Invoked via `piqley plugin rules edit <plugin-id>`.

The architecture splits into two layers:
- **PiqleyCore** provides validation, field catalogs, rule building, and stage mutation — shared by CLI and future GUI.
- **CLI** owns field discovery (from installed plugins), the TUI wizard (TermKit), and all file I/O.

## Goals

- **Discovery** — users can browse available fields and actions without knowing the JSON schema.
- **Syntax safety** — invalid rules cannot be constructed; validation happens inline at each step.
- **Workflow** — no need to know where stage files live or how to edit JSON by hand.
- **GUI-ready** — Core types translate directly to a future GUI without refactoring.

## Non-Goals

- Plugin developer tooling (dependency declaration, dry-run preview against sample images) — additive later.
- Image folder scanning for field discovery — future improvement (tracked in OmniFocus).
- Subcommand-based non-interactive mode (`piqley plugin rules add --field ... --pattern ...`) — additive later.

---

## PiqleyCore Types

### RuleEditingContext

The central type. The client constructs it by injecting runtime knowledge. Core never discovers anything on its own.

```swift
public struct RuleEditingContext: Sendable {
    /// Available fields organized by source (user-facing term for namespace).
    /// Client builds this from installed plugins + metadata field catalog.
    public let availableFields: [String: [FieldInfo]]

    /// The plugin being edited.
    public let pluginIdentifier: String

    /// Existing stages and their rules (loaded from disk by client).
    public var stages: [String: StageConfig]

    public init(
        availableFields: [String: [FieldInfo]],
        pluginIdentifier: String,
        stages: [String: StageConfig]
    )
}
```

**Query methods** the client calls at each wizard step:

```swift
extension RuleEditingContext {
    /// Source names available for matching (e.g. "original", "read", "exif-tagger").
    public func availableSources() -> [String]

    /// Fields within a source, sorted: custom → EXIF → IPTC/XMP → TIFF.
    public func fields(in source: String) -> [FieldInfo]

    /// The four known actions: add, remove, replace, removeField.
    public func validActions() -> [String]

    /// Stage names that have stage files for this plugin.
    public func stageNames() -> [String]

    /// Existing rules in a stage/slot. Returns empty array if stage or slot has no rules.
    public func rules(forStage stage: String, slot: RuleSlot) -> [Rule]

    /// Whether a stage has a binary configured (determines if pre/post choice is shown).
    public func stageHasBinary(_ stage: String) -> Bool

    /// Validate a match config.
    public func validateMatch(field: String, pattern: String) -> Result<Void, RuleValidationError>

    /// Validate an emit/write config.
    public func validateEmit(_ config: EmitConfig) -> Result<Void, RuleValidationError>
}
```

### FieldInfo

```swift
public struct FieldInfo: Sendable, Equatable {
    public let name: String           // e.g. "TIFF:Model"
    public let source: String         // e.g. "original", "exif-tagger"
    public let qualifiedName: String  // "original:TIFF:Model"
    public let category: FieldCategory

    public init(name: String, source: String, qualifiedName: String, category: FieldCategory)
}

public enum FieldCategory: Int, Sendable, Comparable {
    case custom = 0
    case exif = 1
    case iptc = 2
    case xmp = 3
    case tiff = 4

    public static func < (lhs: FieldCategory, rhs: FieldCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

Fields sort by `category` first (custom → EXIF → IPTC/XMP → TIFF), then alphabetically within each category.

### RuleBuilder

Fluent builder that enforces valid construction. The wizard feeds user choices in; the builder validates immediately.

```swift
public struct RuleBuilder: Sendable {
    private let context: RuleEditingContext
    private var match: MatchConfig?
    private var emitActions: [EmitConfig] = []
    private var writeActions: [EmitConfig] = []

    public init(context: RuleEditingContext)

    /// Set the match config. Returns validation result immediately.
    public mutating func setMatch(field: String, pattern: String)
        -> Result<Void, RuleValidationError>

    /// Add an emit action. Returns validation result immediately.
    public mutating func addEmit(_ config: EmitConfig)
        -> Result<Void, RuleValidationError>

    /// Add a write action. Returns validation result immediately.
    public mutating func addWrite(_ config: EmitConfig)
        -> Result<Void, RuleValidationError>

    /// Reset the builder to start over.
    public mutating func reset()

    /// Build the final rule. Fails if match is not set or no actions exist.
    public func build() -> Result<Rule, RuleValidationError>
}
```

### RuleValidationError

Localized errors with recovery suggestions, suitable for display in both CLI and GUI.

```swift
public enum RuleValidationError: Error, LocalizedError, Sendable {
    case emptyField
    case invalidPattern(String, underlying: Error)
    case unknownAction(String)
    case missingValues(action: String)
    case conflictingFields(action: String)
    case noMatch
    case noActions

    public var errorDescription: String? {
        switch self {
        case .emptyField:
            "The field name is empty."
        case let .invalidPattern(pattern, underlying):
            "The pattern \"\(pattern)\" is not valid: \(underlying.localizedDescription)"
        case let .unknownAction(action):
            "Unknown action \"\(action)\"."
        case let .missingValues(action):
            "The \"\(action)\" action requires values."
        case let .conflictingFields(action):
            "The \"\(action)\" action has conflicting fields — use either values or replacements, not both."
        case .noMatch:
            "No match condition has been set."
        case .noActions:
            "The rule has no emit or write actions."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyField:
            "Enter a field name, or select one from the list."
        case .invalidPattern:
            "Check the pattern syntax. Use plain text for exact match, prefix with \"glob:\" for wildcards, or \"regex:\" for regular expressions."
        case .unknownAction:
            "Use one of: add, remove, replace, or removeField."
        case let .missingValues(action):
            if action == "replace" {
                return "Add at least one pattern → replacement pair."
            }
            return "Provide at least one value."
        case let .conflictingFields(action):
            if action == "replace" {
                return "The replace action uses replacements, not values."
            }
            return "The \(action) action uses values, not replacements."
        case .noMatch:
            "Go back and set a match condition (source + field + pattern)."
        case .noActions:
            "Add at least one emit or write action."
        }
    }
}
```

### StageConfig Mutations

New mutating methods on the existing `StageConfig` type. Properties change from `let` to `var`.

```swift
public enum RuleSlot: Sendable {
    case pre
    case post
}

extension StageConfig {
    /// Append a rule to the end of the specified slot.
    public mutating func appendRule(_ rule: Rule, slot: RuleSlot)

    /// Remove the rule at the given index in the specified slot.
    /// Throws if index is out of bounds.
    public mutating func removeRule(at index: Int, slot: RuleSlot)

    /// Move a rule from one position to another within the same slot.
    /// Throws if either index is out of bounds.
    public mutating func moveRule(from source: Int, to destination: Int, slot: RuleSlot)

    /// Replace the rule at the given index in the specified slot.
    /// Used by the edit flow. Throws if index is out of bounds.
    public mutating func replaceRule(at index: Int, with rule: Rule, slot: RuleSlot)
}
```

### Hardcoded Field Catalog

A static catalog of common metadata fields photographers encounter. Lives in PiqleyCore so both CLI and GUI share it.

```swift
public struct MetadataFieldCatalog {
    /// Common EXIF fields.
    public static let exifFields: [String]

    /// Common IPTC fields.
    public static let iptcFields: [String]

    /// Common XMP fields.
    public static let xmpFields: [String]

    /// Common TIFF fields.
    public static let tiffFields: [String]

    /// All fields as FieldInfo for a given source name (e.g. "original" or "read").
    public static func fields(forSource source: String) -> [FieldInfo]
}
```

### Validation Extraction

The validation logic currently in `RuleEvaluator.compileEmitAction` is extracted into static methods on `RuleEditingContext` so both the wizard (via `RuleBuilder`) and the evaluator can use the same checks. `RuleEvaluator` is updated to call these shared validators instead of duplicating the logic.

---

## CLI Layer

### Command

```swift
struct PluginRulesEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Edit rules for a plugin."
    )

    @Argument(help: "The plugin identifier to edit rules for.")
    var pluginID: String

    func run() async throws {
        // 1. Resolve plugin directory from pluginID
        // 2. Load manifest.json → get dependencies
        // 3. Load stage files → [String: StageConfig]
        // 4. Discover available fields:
        //    a. MetadataFieldCatalog.fields(forSource: "original")
        //    b. MetadataFieldCatalog.fields(forSource: "read")
        //    c. For each dependency: load its manifest, get declared fields
        // 5. Build RuleEditingContext
        // 6. Launch RulesWizardApp(context:)
        // 7. On return: write modified StageConfig(s) back to stage files
    }
}
```

This command lives under the existing `PluginCommand` group, making the invocation `piqley plugin rules edit <plugin-id>`.

### TUI Wizard (TermKit)

The wizard is a TermKit `Application` with a stack of screens. Each screen is a `Frame` (bordered panel) with a footer showing available keyboard shortcuts.

**Screen hierarchy:**

```
RulesWizardApp
├── StageSelectScreen       — ListView of stages with rule counts
├── RuleListScreen          — ListView of rules + filter + action keys
│   ├── Paging              — pgup/pgdn for large lists
│   ├── Live filter         — f key activates TextField, keystrokes filter immediately
│   │                         f + text + typing = live filter
│   │                         f + enter = prompt mode, type filter, press enter to apply
│   └── Actions             — a (add), e (edit), d (delete), r (reorder)
├── RuleEditorScreen        — multi-step panel with pinned context
│   ├── SourceSelectView    — ListView of sources with descriptions
│   ├── FieldSelectView     — grouped ListView sorted by category + filter
│   ├── PatternInputView    — TextField with inline validation feedback
│   ├── EmitActionView      — action selection → detail input (field, values/replacements)
│   ├── WriteActionView     — same structure as emit
│   └── ConfirmView         — full summary, save/edit/cancel
```

**Key UX behaviors:**

- **Full-screen TUI** — each step takes over the terminal display buffer via TermKit's alternate screen.
- **Pinned context** — during rule creation, the match config (and later emit actions) display at the top of the screen as a `Label` so the user always sees what they've built so far.
- **No binary = skip slot choice** — if `stageHasBinary()` returns false, rules go to `preRules` automatically without asking.
- **Live filtering** — pressing `f` activates a `TextField` at the top of any list. Keystrokes immediately filter the list. Matched text is highlighted. Press `esc` to clear the filter. Filter applies to field name, source name, pattern text, and action summaries.
- **Field sorting** — fields display in sections: custom fields first, then EXIF, IPTC/XMP, TIFF. Section headers shown as non-selectable labels in the list.
- **Validation inline** — errors from `RuleBuilder` display immediately below the input as styled text with the recovery suggestion. The user retries without losing their place.
- **Navigation** — `↑↓` to navigate, `⏎` to select, `q` to go back one screen, `Ctrl+C` to exit entirely.

### Stage File I/O

- **Read:** existing `PluginDiscovery.loadStages()` (no changes needed).
- **Write:** `JSONEncoder` with `.prettyPrinted` and `.sortedKeys`, written to `stage-{hookName}.json` in the plugin directory.
- **Atomic writes** — write to a temp file and rename, so a crash mid-write doesn't corrupt the stage file.

---

## User-Facing Terminology

| Internal term | User-facing term | Where used |
|---------------|-----------------|------------|
| namespace | source | TUI prompts, error messages |
| preRules / postRules | pre-rules / post-rules | TUI labels (only shown when binary exists) |
| emit | emit | TUI labels ("modifies plugin output") |
| write | write | TUI labels ("modifies file metadata") |
| MatchConfig | match | TUI section header |
| EmitConfig | action | TUI prompts |

---

## Future Additions (not in scope)

These can be added without refactoring the core architecture:

- **Image folder scanning** for field discovery — augments the hardcoded catalog with fields found in actual images. (Tracked in OmniFocus.)
- **Plugin developer mode** — unlocked by context (being inside a plugin project). Adds dependency declaration, dry-run preview, bulk operations.
- **Non-interactive subcommands** — `piqley plugin rules add --field ... --pattern ...` for scripting.
- **GUI client** — drives the same `RuleEditingContext` and `RuleBuilder` with dropdowns/form fields instead of TUI prompts.
