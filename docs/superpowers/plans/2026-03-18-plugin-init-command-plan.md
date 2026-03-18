# Plugin Init Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `piqley plugin init` to scaffold declarative-only plugins with manifest and config files.

**Architecture:** New `InitSubcommand` in `PluginCommand.swift` using `PiqleyPluginSDK` builders to construct and write `manifest.json` and `config.json`. Three modes: interactive (default), interactive + `--no-examples`, and non-interactive.

**Tech Stack:** Swift, swift-argument-parser, PiqleyPluginSDK (builders + file writers), PiqleyCore (types), swift-testing

**Spec:** `docs/superpowers/specs/2026-03-18-plugin-init-command-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Package.swift` | Add PiqleyPluginSDK dependency |
| Modify | `Sources/piqley/CLI/PluginCommand.swift` | Add `InitSubcommand` to subcommands list and implement it |
| Create | `Tests/piqleyTests/PluginInitTests.swift` | Tests for all three modes, validation, and error cases |

---

### Task 1: Add PiqleyPluginSDK dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the SDK package dependency and target dependency**

The SDK has no version tags yet, so use a branch reference. Add to `Package.swift`:

```swift
// In dependencies array, add:
.package(url: "https://github.com/josephquigley/piqley-plugin-sdk.git", branch: "main"),

// In the piqley executable target dependencies, add:
.product(name: "PiqleyPluginSDK", package: "piqley-plugin-sdk"),
```

- [ ] **Step 2: Resolve and build**

Run: `swift package resolve && swift build`
Expected: Clean build with no errors.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add PiqleyPluginSDK dependency"
```

---

### Task 2: Write validation tests

**Files:**
- Create: `Tests/piqleyTests/PluginInitTests.swift`

- [ ] **Step 1: Write tests for name validation**

These test the validation logic that will live in `InitSubcommand`. Test cases:
- Reject empty name
- Reject `"original"` (reserved by state engine)
- Reject names with path separators (`/`, `..`)
- Reject names with whitespace
- Accept a valid name like `"my-plugin"`

```swift
import Testing
import Foundation
import PiqleyCore
import PiqleyPluginSDK
@testable import piqley

@Suite("PluginInit")
struct PluginInitTests {
    @Test("rejects empty name")
    func testRejectsEmptyName() {
        #expect(throws: (any Error).self) {
            try InitSubcommand.validatePluginName("")
        }
    }

    @Test("rejects reserved name 'original'")
    func testRejectsOriginal() {
        #expect(throws: (any Error).self) {
            try InitSubcommand.validatePluginName("original")
        }
    }

    @Test("rejects name with forward slash")
    func testRejectsForwardSlash() {
        #expect(throws: (any Error).self) {
            try InitSubcommand.validatePluginName("../evil")
        }
    }

    @Test("rejects name with backslash")
    func testRejectsBackslash() {
        #expect(throws: (any Error).self) {
            try InitSubcommand.validatePluginName("foo\\bar")
        }
    }

    @Test("rejects name with whitespace")
    func testRejectsWhitespace() {
        #expect(throws: (any Error).self) {
            try InitSubcommand.validatePluginName("my plugin")
        }
    }

    @Test("rejects whitespace-only name")
    func testRejectsWhitespaceOnly() {
        #expect(throws: (any Error).self) {
            try InitSubcommand.validatePluginName("   ")
        }
    }

    @Test("accepts valid plugin name")
    func testAcceptsValidName() throws {
        try InitSubcommand.validatePluginName("my-plugin")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginInit`
Expected: Compilation error — `InitSubcommand` does not exist yet.

- [ ] **Step 3: Commit**

```bash
git add Tests/piqleyTests/PluginInitTests.swift
git commit -m "test: add failing tests for plugin init name validation"
```

---

### Task 3: Implement InitSubcommand with validation and non-interactive mode

**Files:**
- Modify: `Sources/piqley/CLI/PluginCommand.swift`

- [ ] **Step 1: Add InitSubcommand to PluginCommand**

Register it in the subcommands array:

```swift
static let configuration = CommandConfiguration(
    commandName: "plugin",
    abstract: "Manage plugins",
    subcommands: [SetupSubcommand.self, InitSubcommand.self]
)
```

- [ ] **Step 2: Implement InitSubcommand**

Add the full subcommand after `SetupSubcommand` in the same file. This covers non-interactive mode and validation. Interactive mode will be added in Task 5.

```swift
struct InitSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new declarative-only plugin"
    )

    @Argument(help: "Plugin name")
    var pluginName: String?

    @Flag(help: "Skip example rules in generated config")
    var noExamples = false

    @Flag(help: "Non-interactive mode (requires name argument)")
    var nonInteractive = false

    static func validatePluginName(_ name: String) throws {
        if name.isEmpty {
            throw ValidationError("Plugin name must not be empty")
        }
        if name == "original" {
            throw ValidationError("'original' is a reserved name")
        }
        if name.contains("/") || name.contains("\\") || name.contains("..") {
            throw ValidationError("Plugin name must not contain path separators")
        }
        if name.contains(where: { $0.isWhitespace }) {
            throw ValidationError("Plugin name must not contain whitespace")
        }
    }

    func run() throws {
        try execute(pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory)
    }

    /// Core logic, extracted for testability (injectable plugins directory).
    func execute(pluginsDirectory: URL) throws {
        let name: String
        let hook: Hook

        if nonInteractive {
            guard let pluginName else {
                throw ValidationError("Non-interactive mode requires a plugin name argument")
            }
            name = pluginName
            hook = .preProcess
        } else {
            // Interactive mode — implemented in Task 5
            // For now, require name argument in all modes
            guard let pluginName else {
                throw ValidationError("Plugin name argument required (interactive mode not yet implemented)")
            }
            name = pluginName
            hook = .preProcess
        }

        try Self.validatePluginName(name)

        let pluginDir = pluginsDirectory.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: pluginDir.path) {
            throw ValidationError("Plugin '\(name)' already exists at \(pluginDir.path)")
        }

        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest = try buildManifest {
            Name(name)
            ProtocolVersion("1")
            Hooks {
                HookEntry(hook)
            }
        }
        try manifest.writeValidated(to: pluginDir)

        let config: PluginConfig
        if !noExamples && !nonInteractive {
            config = buildConfig {
                Rules {
                    ConfigRule(
                        match: .field(.original(.model), pattern: .exact("Canon EOS R5")),
                        emit: .values(field: "tags", ["Canon", "EOS R5"])
                    )
                }
            }
        } else {
            config = buildConfig {}
        }
        try config.write(to: pluginDir)

        print("Created plugin '\(name)' at \(pluginDir.path)")
    }
}
```

Add the import at the top of the file:

```swift
import PiqleyPluginSDK
```

- [ ] **Step 3: Run validation tests**

Run: `swift test --filter PluginInit`
Expected: All 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/piqley/CLI/PluginCommand.swift
git commit -m "feat: add piqley plugin init with validation and non-interactive mode"
```

---

### Task 4: Write end-to-end tests for file generation

**Files:**
- Modify: `Tests/piqleyTests/PluginInitTests.swift`

These tests exercise `InitSubcommand.execute(pluginsDirectory:)` with a temp directory, verifying the actual command wiring — not just the SDK builders.

- [ ] **Step 1: Add a temp directory helper**

```swift
/// Creates a unique temp directory for test isolation. Caller is responsible for cleanup.
func makeTempPluginsDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-init-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

- [ ] **Step 2: Write test for non-interactive end-to-end**

```swift
@Test("non-interactive creates manifest and empty config")
func testNonInteractiveCreatesFiles() throws {
    let dir = try makeTempPluginsDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    var cmd = InitSubcommand()
    cmd.pluginName = "test-plugin"
    cmd.nonInteractive = true
    try cmd.execute(pluginsDirectory: dir)

    // Verify manifest
    let manifestData = try Data(contentsOf: dir.appendingPathComponent("test-plugin/manifest.json"))
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
    #expect(decoded.name == "test-plugin")
    #expect(decoded.pluginProtocolVersion == "1")
    #expect(decoded.hooks["pre-process"] != nil)
    #expect(decoded.hooks["pre-process"]?.command == nil)

    // Verify config
    let configData = try Data(contentsOf: dir.appendingPathComponent("test-plugin/config.json"))
    let decodedConfig = try JSONDecoder().decode(PluginConfig.self, from: configData)
    #expect(decodedConfig.rules.isEmpty)
}
```

- [ ] **Step 3: Write test for --no-examples flag**

```swift
@Test("no-examples flag produces empty rules")
func testNoExamplesFlag() throws {
    let dir = try makeTempPluginsDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    var cmd = InitSubcommand()
    cmd.pluginName = "no-ex-plugin"
    cmd.noExamples = true
    try cmd.execute(pluginsDirectory: dir)

    let configData = try Data(contentsOf: dir.appendingPathComponent("no-ex-plugin/config.json"))
    let decodedConfig = try JSONDecoder().decode(PluginConfig.self, from: configData)
    #expect(decodedConfig.rules.isEmpty)
}
```

- [ ] **Step 4: Write test for example rule generation**

```swift
@Test("default mode includes example rule with correct structure")
func testExampleRuleGeneration() throws {
    let dir = try makeTempPluginsDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    var cmd = InitSubcommand()
    cmd.pluginName = "example-plugin"
    try cmd.execute(pluginsDirectory: dir)

    let configData = try Data(contentsOf: dir.appendingPathComponent("example-plugin/config.json"))
    let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
    #expect(config.rules.count == 1)
    #expect(config.rules[0].match.field == "original:TIFF:Model")
    #expect(config.rules[0].match.pattern == "Canon EOS R5")
    #expect(config.rules[0].emit.field == "tags")
    #expect(config.rules[0].emit.values == ["Canon", "EOS R5"])
}
```

- [ ] **Step 5: Write test for directory-already-exists error**

```swift
@Test("rejects init when plugin directory already exists")
func testRejectsExistingDirectory() throws {
    let dir = try makeTempPluginsDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Pre-create the plugin directory
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("existing-plugin"),
        withIntermediateDirectories: true
    )

    var cmd = InitSubcommand()
    cmd.pluginName = "existing-plugin"
    cmd.nonInteractive = true
    #expect(throws: (any Error).self) {
        try cmd.execute(pluginsDirectory: dir)
    }
}
```

- [ ] **Step 6: Write test for non-interactive without name**

```swift
@Test("non-interactive without name throws error")
func testNonInteractiveRequiresName() throws {
    let dir = try makeTempPluginsDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    var cmd = InitSubcommand()
    cmd.nonInteractive = true
    #expect(throws: (any Error).self) {
        try cmd.execute(pluginsDirectory: dir)
    }
}
```

- [ ] **Step 7: Run tests**

Run: `swift test --filter PluginInit`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add Tests/piqleyTests/PluginInitTests.swift
git commit -m "test: add end-to-end tests for plugin init file generation"
```

---

### Task 5: Add interactive mode

**Files:**
- Modify: `Sources/piqley/CLI/PluginCommand.swift`

- [ ] **Step 1: Implement interactive prompts**

Replace the placeholder interactive block in `InitSubcommand.run()` with actual prompts. Use `readLine()` for input (matching the pattern in `SetupCommand` and `PluginSetupScanner`).

The interactive block should:
1. Prompt for plugin name if not provided as argument
2. Present the canonical hooks as a numbered list and prompt for selection

```swift
if nonInteractive {
    guard let pluginName else {
        throw ValidationError("Non-interactive mode requires a plugin name argument")
    }
    name = pluginName
    hook = .preProcess
} else {
    if let pluginName {
        name = pluginName
    } else {
        print("Plugin name: ", terminator: "")
        guard let input = readLine(), !input.isEmpty else {
            throw ValidationError("Plugin name must not be empty")
        }
        name = input
    }

    print("\nWhich hook should this plugin run on?")
    let hooks = Hook.canonicalOrder
    for (index, h) in hooks.enumerated() {
        print("  \(index + 1). \(h.rawValue)")
    }
    print("Choose [\(Hook.preProcess.rawValue)]: ", terminator: "")
    let hookInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    if hookInput.isEmpty {
        hook = .preProcess
    } else if let index = Int(hookInput), (1...hooks.count).contains(index) {
        hook = hooks[index - 1]
    } else {
        throw ValidationError("Invalid hook selection: \(hookInput)")
    }
}
```

- [ ] **Step 2: Add hook to example rule when not pre-process**

Update the example rule generation to include the hook in the match config when the user selects a hook other than `pre-process`:

```swift
if !noExamples && !nonInteractive {
    config = buildConfig {
        Rules {
            ConfigRule(
                match: .field(
                    .original(.model),
                    pattern: .exact("Canon EOS R5"),
                    hook: hook == .preProcess ? nil : hook
                ),
                emit: .values(field: "tags", ["Canon", "EOS R5"])
            )
        }
    }
} else {
    config = buildConfig {}
}
```

- [ ] **Step 3: Build and smoke test manually**

Run: `swift build && .build/debug/piqley plugin init --help`
Expected: Help text shows `[name]`, `--no-examples`, and `--non-interactive` flags.

Run: `swift build && .build/debug/piqley plugin init test-declarative --non-interactive`
Expected: Creates plugin at `~/.config/piqley/plugins/test-declarative/` with manifest and empty config.
Clean up: `rm -rf ~/.config/piqley/plugins/test-declarative`

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: All tests pass (existing + new).

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/CLI/PluginCommand.swift
git commit -m "feat: add interactive mode to piqley plugin init"
```
