# SDK Build & Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable plugin authors to package plugins into `.piqleyplugin` files via SDK build CLIs, and enable users to install them via `piqley plugin install`.

**Architecture:** Schema-first design — JSON Schema files in `piqley-plugin-sdk/schemas/` are the canonical spec. Each SDK validates against them. The Swift SDK provides a `piqley-build` executable target. The piqley CLI adds an `InstallSubcommand` that extracts and validates `.piqleyplugin` zip archives.

**Tech Stack:** Swift (SPM), JSON Schema (draft 2020-12), Foundation (zip via `Process` + `ditto`/`zip` CLI), swift-json-schema or similar test-only dependency.

**Spec:** `docs/superpowers/specs/2026-03-18-sdk-build-packaging-design.md`

---

## File Structure

### piqley-plugin-sdk (new files)

| File | Responsibility |
|------|---------------|
| `schemas/manifest.schema.json` | JSON Schema for plugin manifest |
| `schemas/config.schema.json` | JSON Schema for plugin config |
| `schemas/build-manifest.schema.json` | JSON Schema for piqley-build-manifest.json |
| `schemas/plugin-input.schema.json` | JSON Schema for plugin stdin payload |
| `schemas/plugin-output.schema.json` | JSON Schema for plugin stdout lines |
| `swift/PiqleyPluginSDK/BuildManifest.swift` | `BuildManifest` Codable struct for reading `piqley-build-manifest.json` |
| `swift/PiqleyPluginSDK/Packager.swift` | Reads build manifest, validates JSON, assembles zip |
| `Skeletons/swift/piqley-build-manifest.json` | Template build manifest for Swift skeleton |

### piqley-plugin-sdk (modified files)

| File | Change |
|------|--------|
| `Package.swift` | Add `piqley-build` executable target, add test-only JSON Schema validation dependency |

### piqley-plugin-sdk (new test files)

| File | Responsibility |
|------|---------------|
| `swift/Tests/SchemaConformanceTests.swift` | Validate builder output against schema files |
| `swift/Tests/PackagerTests.swift` | Test the packaging pipeline |

### piqley-core (modified files)

| File | Change |
|------|--------|
| `Sources/PiqleyCore/Manifest/PluginManifest.swift` | Migrate `dependencies` from `[String]?` to `[PluginDependency]?` |
| `Sources/PiqleyCore/Manifest/PluginDependency.swift` | New file — `PluginDependency` struct with `url` and `VersionConstraint` |

### piqley-cli (new files)

| File | Responsibility |
|------|---------------|
| `Sources/piqley/CLI/InstallCommand.swift` | `InstallSubcommand` — extracts and installs `.piqleyplugin` files |
| `Tests/piqleyTests/InstallCommandTests.swift` | Tests for install command |

### piqley-cli (modified files)

| File | Change |
|------|--------|
| `Sources/piqley/Constants/PluginDirectory.swift` | Add `bin = "bin"` constant |
| `Sources/piqley/CLI/PluginCommand.swift` | Register `InstallSubcommand` |

---

### Task 1: JSON Schema Files

**Files:**
- Create: `piqley-plugin-sdk/schemas/manifest.schema.json`
- Create: `piqley-plugin-sdk/schemas/config.schema.json`
- Create: `piqley-plugin-sdk/schemas/build-manifest.schema.json`
- Create: `piqley-plugin-sdk/schemas/plugin-input.schema.json`
- Create: `piqley-plugin-sdk/schemas/plugin-output.schema.json`

These schemas are the canonical specification. All other tasks depend on them. Derive the schemas from the existing Swift types in PiqleyCore.

- [ ] **Step 1: Create `manifest.schema.json`**

Reference types:
- `PluginManifest` at `piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`
- `ConfigEntry` at `piqley-core/Sources/PiqleyCore/Manifest/ConfigEntry.swift`
- `HookConfig` at `piqley-core/Sources/PiqleyCore/Manifest/HookConfig.swift`
- `SetupConfig` at `piqley-core/Sources/PiqleyCore/Manifest/SetupConfig.swift`
- `BatchProxyConfig` at `piqley-core/Sources/PiqleyCore/Manifest/BatchProxyConfig.swift`

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://piqley.dev/schemas/manifest.schema.json",
  "title": "Piqley Plugin Manifest",
  "type": "object",
  "required": ["name", "pluginProtocolVersion", "hooks"],
  "properties": {
    "name": { "type": "string", "minLength": 1 },
    "pluginProtocolVersion": { "type": "string", "const": "1" },
    "pluginVersion": {
      "type": "string",
      "pattern": "^\\d+\\.\\d+\\.\\d+$"
    },
    "config": {
      "type": "array",
      "items": { "$ref": "#/$defs/configEntry" }
    },
    "setup": { "$ref": "#/$defs/setupConfig" },
    "dependencies": {
      "type": "array",
      "items": { "$ref": "#/$defs/pluginDependency" }
    },
    "hooks": {
      "type": "object",
      "propertyNames": {
        "enum": ["pre-process", "post-process", "publish", "post-publish"]
      },
      "minProperties": 1,
      "additionalProperties": { "$ref": "#/$defs/hookConfig" }
    }
  },
  "$defs": {
    "configEntry": {
      "oneOf": [
        {
          "type": "object",
          "required": ["key", "type"],
          "properties": {
            "key": { "type": "string" },
            "type": { "enum": ["string", "int", "float", "bool"] },
            "value": {}
          },
          "additionalProperties": false
        },
        {
          "type": "object",
          "required": ["secret_key", "type"],
          "properties": {
            "secret_key": { "type": "string" },
            "type": { "enum": ["string", "int", "float", "bool"] }
          },
          "additionalProperties": false
        }
      ]
    },
    "setupConfig": {
      "type": "object",
      "required": ["command"],
      "properties": {
        "command": { "type": "string" },
        "args": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    },
    "pluginDependency": {
      "type": "object",
      "required": ["url", "version"],
      "properties": {
        "url": {
          "type": "string",
          "pattern": "\\.piqleyplugin$"
        },
        "version": {
          "type": "object",
          "required": ["from", "rule"],
          "properties": {
            "from": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
            "rule": { "enum": ["upToNextMajor", "upToNextMinor", "exact"] }
          },
          "additionalProperties": false
        }
      },
      "additionalProperties": false
    },
    "hookConfig": {
      "type": "object",
      "properties": {
        "command": { "type": "string" },
        "args": { "type": "array", "items": { "type": "string" } },
        "timeout": { "type": "integer", "minimum": 0 },
        "protocol": { "enum": ["json", "pipe"] },
        "successCodes": { "type": "array", "items": { "type": "integer" } },
        "warningCodes": { "type": "array", "items": { "type": "integer" } },
        "criticalCodes": { "type": "array", "items": { "type": "integer" } },
        "batchProxy": { "$ref": "#/$defs/batchProxyConfig" }
      },
      "additionalProperties": false
    },
    "batchProxyConfig": {
      "type": "object",
      "properties": {
        "sort": {
          "type": "object",
          "required": ["key", "order"],
          "properties": {
            "key": { "type": "string" },
            "order": { "enum": ["ascending", "descending"] }
          },
          "additionalProperties": false
        }
      },
      "additionalProperties": false
    }
  }
}
```

Write to `piqley-plugin-sdk/schemas/manifest.schema.json`.

- [ ] **Step 2: Create `config.schema.json`**

Reference types:
- `PluginConfig` at `piqley-core/Sources/PiqleyCore/Config/PluginConfig.swift`
- `Rule` at `piqley-core/Sources/PiqleyCore/Config/Rule.swift`

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://piqley.dev/schemas/config.schema.json",
  "title": "Piqley Plugin Config",
  "type": "object",
  "properties": {
    "values": {
      "type": "object",
      "additionalProperties": true
    },
    "isSetUp": { "type": "boolean" },
    "rules": {
      "type": "array",
      "items": { "$ref": "#/$defs/rule" }
    }
  },
  "$defs": {
    "rule": {
      "type": "object",
      "required": ["match", "emit"],
      "properties": {
        "match": { "$ref": "#/$defs/matchConfig" },
        "emit": {
          "type": "array",
          "items": { "$ref": "#/$defs/emitConfig" }
        }
      },
      "additionalProperties": false
    },
    "matchConfig": {
      "type": "object",
      "required": ["field", "pattern"],
      "properties": {
        "hook": { "type": "string" },
        "field": { "type": "string" },
        "pattern": { "type": "string" }
      },
      "additionalProperties": false
    },
    "emitConfig": {
      "type": "object",
      "required": ["field"],
      "properties": {
        "action": { "type": "string" },
        "field": { "type": "string" },
        "values": { "type": "array", "items": { "type": "string" } },
        "replacements": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["pattern", "replacement"],
            "properties": {
              "pattern": { "type": "string" },
              "replacement": { "type": "string" }
            },
            "additionalProperties": false
          }
        }
      },
      "additionalProperties": false
    }
  }
}
```

Write to `piqley-plugin-sdk/schemas/config.schema.json`.

- [ ] **Step 3: Create `build-manifest.schema.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://piqley.dev/schemas/build-manifest.schema.json",
  "title": "Piqley Build Manifest",
  "type": "object",
  "required": ["pluginName", "pluginProtocolVersion", "bin"],
  "properties": {
    "pluginName": { "type": "string", "minLength": 1 },
    "pluginProtocolVersion": { "type": "string", "const": "1" },
    "bin": {
      "type": "array",
      "items": { "type": "string" },
      "minItems": 1
    },
    "data": {
      "type": "array",
      "items": { "type": "string" }
    },
    "dependencies": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["url", "version"],
        "properties": {
          "url": {
            "type": "string",
            "pattern": "\\.piqleyplugin$"
          },
          "version": {
            "type": "object",
            "required": ["from", "rule"],
            "properties": {
              "from": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
              "rule": { "enum": ["upToNextMajor", "upToNextMinor", "exact"] }
            },
            "additionalProperties": false
          }
        },
        "additionalProperties": false
      }
    }
  },
  "additionalProperties": false
}
```

Write to `piqley-plugin-sdk/schemas/build-manifest.schema.json`.

- [ ] **Step 4: Create `plugin-input.schema.json`**

Reference: `PluginInputPayload` at `piqley-core/Sources/PiqleyCore/Payload/PluginInputPayload.swift`

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://piqley.dev/schemas/plugin-input.schema.json",
  "title": "Piqley Plugin Input Payload",
  "type": "object",
  "required": ["hook", "folderPath", "pluginConfig", "secrets", "executionLogPath", "dataPath", "logPath", "dryRun", "pluginVersion"],
  "properties": {
    "hook": { "type": "string", "enum": ["pre-process", "post-process", "publish", "post-publish"] },
    "folderPath": { "type": "string" },
    "pluginConfig": { "type": "object", "additionalProperties": true },
    "secrets": { "type": "object", "additionalProperties": { "type": "string" } },
    "executionLogPath": { "type": "string" },
    "dataPath": { "type": "string" },
    "logPath": { "type": "string" },
    "dryRun": { "type": "boolean" },
    "state": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "additionalProperties": {
          "type": "object",
          "additionalProperties": true
        }
      }
    },
    "pluginVersion": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "lastExecutedVersion": { "type": ["string", "null"], "pattern": "^\\d+\\.\\d+\\.\\d+$" }
  },
  "additionalProperties": false
}
```

Write to `piqley-plugin-sdk/schemas/plugin-input.schema.json`.

- [ ] **Step 5: Create `plugin-output.schema.json`**

Reference: `PluginOutputLine` at `piqley-core/Sources/PiqleyCore/Payload/PluginOutputLine.swift`

Each newline-delimited JSON line is validated independently against this schema.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://piqley.dev/schemas/plugin-output.schema.json",
  "title": "Piqley Plugin Output Line",
  "type": "object",
  "required": ["type"],
  "oneOf": [
    {
      "properties": {
        "type": { "const": "progress" },
        "message": { "type": "string" }
      },
      "required": ["type", "message"]
    },
    {
      "properties": {
        "type": { "const": "imageResult" },
        "filename": { "type": "string" },
        "success": { "type": "boolean" },
        "error": { "type": ["string", "null"] }
      },
      "required": ["type", "filename", "success"]
    },
    {
      "properties": {
        "type": { "const": "result" },
        "success": { "type": "boolean" },
        "error": { "type": ["string", "null"] },
        "message": { "type": ["string", "null"] },
        "state": {
          "type": "object",
          "additionalProperties": {
            "type": "object",
            "additionalProperties": true
          }
        }
      },
      "required": ["type", "success"]
    }
  ]
}
```

Write to `piqley-plugin-sdk/schemas/plugin-output.schema.json`.

- [ ] **Step 6: Commit schema files**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add schemas/
git commit -m "feat: add JSON Schema files for manifest, config, build manifest, and plugin I/O"
```

---

### Task 2: PiqleyCore — PluginDependency Type Migration

**Files:**
- Create: `piqley-core/Sources/PiqleyCore/Manifest/PluginDependency.swift`
- Modify: `piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift:8`
- Test: `piqley-core/Tests/PiqleyCoreTests/PluginDependencyTests.swift`

Migrate `PluginManifest.dependencies` from `[String]?` to `[PluginDependency]?` where `PluginDependency` has `url: String` and `version: VersionConstraint`.

- [ ] **Step 1: Write the failing test for PluginDependency decoding**

Create `piqley-core/Tests/PiqleyCoreTests/PluginDependencyTests.swift`:

```swift
import Testing
import Foundation
@testable import PiqleyCore

@Suite("PluginDependency")
struct PluginDependencyTests {
    @Test func decodesFromJSON() throws {
        let json = """
        {
            "url": "https://example.com/plugin.piqleyplugin",
            "version": { "from": "1.0.0", "rule": "upToNextMajor" }
        }
        """.data(using: .utf8)!

        let dep = try JSONDecoder().decode(PluginDependency.self, from: json)
        #expect(dep.url == "https://example.com/plugin.piqleyplugin")
        #expect(dep.version.from == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(dep.version.rule == .upToNextMajor)
    }

    @Test func encodesRoundTrip() throws {
        let dep = PluginDependency(
            url: "https://example.com/plugin.piqleyplugin",
            version: VersionConstraint(from: SemanticVersion(major: 2, minor: 0, patch: 0), rule: .exact)
        )
        let data = try JSONEncoder().encode(dep)
        let decoded = try JSONDecoder().decode(PluginDependency.self, from: data)
        #expect(dep == decoded)
    }

    @Test func allRulesRoundTrip() throws {
        for rule in VersionRule.allCases {
            let dep = PluginDependency(
                url: "https://example.com/p.piqleyplugin",
                version: VersionConstraint(from: SemanticVersion(major: 1, minor: 2, patch: 3), rule: rule)
            )
            let data = try JSONEncoder().encode(dep)
            let decoded = try JSONDecoder().decode(PluginDependency.self, from: data)
            #expect(dep == decoded)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter PluginDependencyTests 2>&1 | head -20`
Expected: FAIL — `PluginDependency` type does not exist

- [ ] **Step 3: Implement PluginDependency**

Create `piqley-core/Sources/PiqleyCore/Manifest/PluginDependency.swift`:

```swift
public struct PluginDependency: Codable, Sendable, Equatable {
    public let url: String
    public let version: VersionConstraint

    public init(url: String, version: VersionConstraint) {
        self.url = url
        self.version = version
    }
}

public struct VersionConstraint: Codable, Sendable, Equatable {
    public let from: SemanticVersion
    public let rule: VersionRule

    public init(from: SemanticVersion, rule: VersionRule) {
        self.from = from
        self.rule = rule
    }
}

public enum VersionRule: String, Codable, Sendable, Equatable, CaseIterable {
    case upToNextMajor
    case upToNextMinor
    case exact
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter PluginDependencyTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for PluginManifest with structured dependencies**

Add to `piqley-core/Tests/PiqleyCoreTests/PluginDependencyTests.swift`:

```swift
@Test func manifestDecodesStructuredDependencies() throws {
    let json = """
    {
        "name": "test-plugin",
        "pluginProtocolVersion": "1",
        "hooks": {
            "pre-process": { "command": "./bin/test" }
        },
        "dependencies": [
            {
                "url": "https://example.com/dep.piqleyplugin",
                "version": { "from": "1.0.0", "rule": "exact" }
            }
        ]
    }
    """.data(using: .utf8)!

    let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
    #expect(manifest.dependencies?.count == 1)
    #expect(manifest.dependencies?.first?.url == "https://example.com/dep.piqleyplugin")
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-core && swift test --filter manifestDecodesStructuredDependencies`
Expected: FAIL — `dependencies` is still `[String]?`

- [ ] **Step 7: Migrate PluginManifest.dependencies with backward compatibility**

In `piqley-core/Sources/PiqleyCore/Manifest/PluginManifest.swift`:

1. Change the stored property from `public var dependencies: [String]?` to `public var dependencies: [PluginDependency]?`

2. Add a custom `init(from decoder:)` that tries structured `[PluginDependency]` first, then falls back to `[String]` (converting each string name to a `PluginDependency` with an empty URL for backward compat):

```swift
public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    pluginProtocolVersion = try container.decode(String.self, forKey: .pluginProtocolVersion)
    pluginVersion = try container.decodeIfPresent(SemanticVersion.self, forKey: .pluginVersion)
    config = try container.decodeIfPresent([ConfigEntry].self, forKey: .config) ?? []
    setup = try container.decodeIfPresent(SetupConfig.self, forKey: .setup)
    hooks = try container.decodeIfPresent([String: HookConfig].self, forKey: .hooks) ?? [:]

    // Backward-compatible dependencies decoding
    if let structured = try? container.decodeIfPresent([PluginDependency].self, forKey: .dependencies) {
        dependencies = structured
    } else if let names = try? container.decodeIfPresent([String].self, forKey: .dependencies) {
        // Legacy format: plain string names with no URL/version
        dependencies = names.map { PluginDependency(name: $0) }
    } else {
        dependencies = nil
    }
}
```

3. Add a convenience initializer to `PluginDependency` for legacy name-only deps:

```swift
/// Legacy initializer for backward compatibility with string-only dependencies
public init(name: String) {
    self.url = ""
    self.version = VersionConstraint(from: SemanticVersion(major: 0, minor: 0, patch: 0), rule: .exact)
}
```

- [ ] **Step 8: Migrate DependencyBuilder in ManifestBuilder.swift**

In `piqley-plugin-sdk/swift/PiqleyPluginSDK/Builders/ManifestBuilder.swift`, update the `DependencyBuilder` result builder and `Dependencies` component to produce `[PluginDependency]` instead of `[String]`:

```swift
@resultBuilder
public enum DependencyBuilder {
    public static func buildBlock(_ components: PluginDependency...) -> [PluginDependency] {
        components
    }

    public static func buildExpression(_ expression: PluginDependency) -> PluginDependency {
        expression
    }
}

public struct Dependencies: ManifestComponent {
    let deps: [PluginDependency]

    public init(@DependencyBuilder _ builder: () -> [PluginDependency]) {
        self.deps = builder()
    }
}
```

Update `buildManifest` function to assign `dependencies = component.deps` with the new type.

Also update `InitSubcommand` in `piqley-cli/Sources/piqley/CLI/PluginCommand.swift` — remove the `Dependencies { "example-dependency" }` usage since `plugin init` creates declarative-only plugins. Set dependencies to nil or remove the `Dependencies` block entirely.

- [ ] **Step 9: Write backward compatibility test**

Add to `piqley-core/Tests/PiqleyCoreTests/PluginDependencyTests.swift`:

```swift
@Test func manifestDecodesLegacyStringDependencies() throws {
    let json = """
    {
        "name": "legacy-plugin",
        "pluginProtocolVersion": "1",
        "hooks": { "pre-process": { "command": "./bin/test" } },
        "dependencies": ["other-plugin", "another-plugin"]
    }
    """.data(using: .utf8)!

    let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
    #expect(manifest.dependencies?.count == 2)
}
```

- [ ] **Step 10: Run all tests across all three repos**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift test
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test
```

Expected: All PASS

- [ ] **Step 11: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core
git add Sources/PiqleyCore/Manifest/PluginDependency.swift Tests/PiqleyCoreTests/PluginDependencyTests.swift Sources/PiqleyCore/Manifest/PluginManifest.swift
git commit -m "feat: migrate PluginManifest.dependencies to structured PluginDependency type"
```

Also commit any changes in piqley-plugin-sdk and piqley-cli from the builder/init updates.

---

### Task 3: Swift SDK — Schema Conformance Tests

**Files:**
- Modify: `piqley-plugin-sdk/Package.swift`
- Create: `piqley-plugin-sdk/swift/Tests/SchemaConformanceTests.swift`

Add a JSON Schema validation library as a **test-only** dependency. Tests emit JSON from the builder APIs and validate against the schema files.

- [ ] **Step 1: Add test-only JSON Schema dependency to Package.swift**

In `piqley-plugin-sdk/Package.swift`, add a JSON Schema validation dependency. Use a Swift JSON Schema library (research available options — e.g. `kylef/JSONSchema.swift` or similar). Add it as a dependency only on the test target, not the library target.

```swift
// In dependencies array:
.package(url: "https://github.com/<author>/<json-schema-lib>", from: "<version>"),

// In test target dependencies:
.testTarget(
    name: "PiqleyPluginSDKTests",
    dependencies: [
        "PiqleyPluginSDK",
        .product(name: "<ProductName>", package: "<json-schema-lib>"),
    ],
    resources: [.copy("../../schemas")]
),
```

Note: The schemas directory must be accessible from the test target. SPM resource paths are relative to the target source directory (`swift/Tests/`). The path `../../schemas` traverses up to the package root then into `schemas/`. Verify this works with `swift build` — if SPM rejects paths outside the target, create a symlink at `swift/Tests/schemas -> ../../schemas` instead.

- [ ] **Step 2: Write schema conformance tests**

Create `piqley-plugin-sdk/swift/Tests/SchemaConformanceTests.swift`:

```swift
import Testing
import Foundation
import PiqleyPluginSDK
// import the JSON Schema validation library

@Suite("Schema Conformance")
struct SchemaConformanceTests {

    // MARK: - Helpers

    private func loadSchema(named name: String) throws -> Data {
        // Load from test bundle resources
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "schemas")!
        return try Data(contentsOf: url)
    }

    // MARK: - Manifest Schema

    @Test func validManifestConformsToSchema() throws {
        let manifest = try buildManifest {
            Name("test-plugin")
            ProtocolVersion("1")
            PluginVersion("1.0.0")
            Hooks {
                HookEntry(.preProcess, command: "./bin/test-plugin")
            }
        }
        let json = try manifest.encode()
        let schema = try loadSchema(named: "manifest.schema")
        // Validate json against schema — exact API depends on chosen library
        // #expect(schema.validate(json).isValid)
    }

    @Test func manifestWithAllFieldsConformsToSchema() throws {
        let manifest = try buildManifest {
            Name("full-plugin")
            ProtocolVersion("1")
            PluginVersion("2.0.0")
            ConfigEntries {
                Value("endpoint", type: .string, default: "https://example.com")
                Secret("API_KEY", type: .string)
            }
            Setup(command: "./bin/full-plugin", args: ["--setup"])
            Dependencies {
                PluginDependency(
                    url: "https://example.com/dep.piqleyplugin",
                    version: VersionConstraint(from: SemanticVersion(major: 1, minor: 0, patch: 0), rule: .exact)
                )
            }
            Hooks {
                HookEntry(.preProcess, command: "./bin/full-plugin", args: ["--pre"])
                HookEntry(.publish, command: "./bin/full-plugin", args: ["--publish"])
            }
        }
        let json = try manifest.encode()
        let schema = try loadSchema(named: "manifest.schema")
        // Validate json against schema
    }

    @Test func invalidProtocolVersionRejectedBySchema() throws {
        // Manually craft JSON with wrong protocol version
        let json = """
        {
            "name": "bad-plugin",
            "pluginProtocolVersion": "99",
            "hooks": { "pre-process": { "command": "./bin/bad" } }
        }
        """.data(using: .utf8)!
        let schema = try loadSchema(named: "manifest.schema")
        // Validate should fail
    }

    @Test func invalidHookNameRejectedBySchema() throws {
        let json = """
        {
            "name": "bad-plugin",
            "pluginProtocolVersion": "1",
            "hooks": { "not-a-real-hook": { "command": "./bin/bad" } }
        }
        """.data(using: .utf8)!
        let schema = try loadSchema(named: "manifest.schema")
        // Validate should fail
    }

    // MARK: - Config Schema

    @Test func validConfigConformsToSchema() throws {
        let config = buildConfig {
            Values {
                "endpoint" => "https://example.com"
                "count" => 42
            }
        }
        let encoder = JSONEncoder()
        let json = try encoder.encode(config)
        let schema = try loadSchema(named: "config.schema")
        // Validate json against schema
    }

    // MARK: - Build Manifest Schema

    @Test func validBuildManifestConformsToSchema() throws {
        let json = """
        {
            "pluginName": "my-plugin",
            "pluginProtocolVersion": "1",
            "bin": [".build/release/my-plugin"],
            "data": [],
            "dependencies": []
        }
        """.data(using: .utf8)!
        let schema = try loadSchema(named: "build-manifest.schema")
        // Validate json against schema
    }

    // MARK: - Plugin I/O Schemas

    @Test func validPluginInputConformsToSchema() throws {
        let json = """
        {
            "hook": "pre-process",
            "folderPath": "/tmp/photos",
            "pluginConfig": { "key": "value" },
            "secrets": { "API_KEY": "secret" },
            "executionLogPath": "/tmp/log.jsonl",
            "dataPath": "/tmp/data",
            "logPath": "/tmp/logs",
            "dryRun": false,
            "pluginVersion": "1.0.0"
        }
        """.data(using: .utf8)!
        let schema = try loadSchema(named: "plugin-input.schema")
        // Validate json against schema
    }

    @Test func validPluginOutputProgressConformsToSchema() throws {
        let json = """
        { "type": "progress", "message": "Processing image 1 of 10" }
        """.data(using: .utf8)!
        let schema = try loadSchema(named: "plugin-output.schema")
        // Validate json against schema
    }

    @Test func validPluginOutputResultConformsToSchema() throws {
        let json = """
        { "type": "result", "success": true }
        """.data(using: .utf8)!
        let schema = try loadSchema(named: "plugin-output.schema")
        // Validate json against schema
    }
}
```

Note: The exact validation API calls depend on which JSON Schema library is chosen. The test structure is what matters — fill in the validation calls once the dependency is selected.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter SchemaConformanceTests`
Expected: FAIL (or compile error if dependency not wired yet)

- [ ] **Step 4: Wire up the schema validation helper and make tests pass**

Implement the `loadSchema` helper and validation calls using the chosen library. Ensure all valid inputs pass and invalid inputs are rejected.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter SchemaConformanceTests`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add Package.swift swift/Tests/SchemaConformanceTests.swift
git commit -m "test: add schema conformance tests with JSON Schema validation"
```

---

### Task 4: Swift SDK — Build CLI and Packager

**Files:**
- Create: `piqley-plugin-sdk/swift/PiqleyPluginSDK/BuildManifest.swift`
- Create: `piqley-plugin-sdk/swift/PiqleyPluginSDK/Packager.swift`
- Create: `piqley-plugin-sdk/swift/PiqleyBuild/main.swift`
- Modify: `piqley-plugin-sdk/Package.swift`
- Test: `piqley-plugin-sdk/swift/Tests/PackagerTests.swift`

The `piqley-build` executable reads `piqley-build-manifest.json`, validates JSON files against schemas, and produces a `.piqleyplugin` zip.

- [ ] **Step 1: Write the failing test for BuildManifest decoding**

Create `piqley-plugin-sdk/swift/Tests/PackagerTests.swift`:

```swift
import Testing
import Foundation
@testable import PiqleyPluginSDK

@Suite("Packager")
struct PackagerTests {

    @Test func decodesBuildManifest() throws {
        let json = """
        {
            "pluginName": "test-plugin",
            "pluginProtocolVersion": "1",
            "bin": [".build/release/test-plugin"],
            "data": ["resources/"],
            "dependencies": []
        }
        """.data(using: .utf8)!

        let buildManifest = try JSONDecoder().decode(BuildManifest.self, from: json)
        #expect(buildManifest.pluginName == "test-plugin")
        #expect(buildManifest.pluginProtocolVersion == "1")
        #expect(buildManifest.bin == [".build/release/test-plugin"])
        #expect(buildManifest.data == ["resources/"])
        #expect(buildManifest.dependencies.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter decodesBuildManifest`
Expected: FAIL — `BuildManifest` does not exist

- [ ] **Step 3: Implement BuildManifest**

Create `piqley-plugin-sdk/swift/PiqleyPluginSDK/BuildManifest.swift`:

```swift
import Foundation
import PiqleyCore

public struct BuildManifest: Codable, Sendable, Equatable {
    public let pluginName: String
    public let pluginProtocolVersion: String
    public let bin: [String]
    public let data: [String]
    public let dependencies: [PluginDependency]

    public init(
        pluginName: String,
        pluginProtocolVersion: String,
        bin: [String],
        data: [String] = [],
        dependencies: [PluginDependency] = []
    ) {
        self.pluginName = pluginName
        self.pluginProtocolVersion = pluginProtocolVersion
        self.bin = bin
        self.data = data
        self.dependencies = dependencies
    }

    public static func load(from directory: URL) throws -> BuildManifest {
        let url = directory.appendingPathComponent("piqley-build-manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BuildManifest.self, from: data)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter decodesBuildManifest`
Expected: PASS

- [ ] **Step 5: Write the failing test for Packager**

Add to `piqley-plugin-sdk/swift/Tests/PackagerTests.swift`:

```swift
@Test func packagerProducesZip() throws {
    // Set up a temp directory with:
    // - piqley-build-manifest.json
    // - manifest.json
    // - config.json
    // - A fake binary file in bin path
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Write build manifest
    let buildManifest = """
    {
        "pluginName": "test-plugin",
        "pluginProtocolVersion": "1",
        "bin": ["fake-binary"],
        "data": [],
        "dependencies": []
    }
    """
    try buildManifest.write(to: tmpDir.appendingPathComponent("piqley-build-manifest.json"), atomically: true, encoding: .utf8)

    // Write manifest.json
    let manifest = """
    {
        "name": "test-plugin",
        "pluginProtocolVersion": "1",
        "hooks": { "pre-process": { "command": "./bin/fake-binary" } }
    }
    """
    try manifest.write(to: tmpDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    // Write config.json
    let config = """
    { "values": {}, "rules": [] }
    """
    try config.write(to: tmpDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    // Write fake binary
    try "#!/bin/sh".write(to: tmpDir.appendingPathComponent("fake-binary"), atomically: true, encoding: .utf8)

    // Run packager
    let outputURL = try Packager.package(directory: tmpDir)

    // Verify output file exists and has .piqleyplugin extension
    #expect(outputURL.pathExtension == "piqleyplugin")
    #expect(outputURL.lastPathComponent == "test-plugin.piqleyplugin")
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
}

@Test func packagerFailsOnNameMismatch() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try """
    { "pluginName": "plugin-a", "pluginProtocolVersion": "1", "bin": ["x"], "data": [], "dependencies": [] }
    """.write(to: tmpDir.appendingPathComponent("piqley-build-manifest.json"), atomically: true, encoding: .utf8)

    try """
    { "name": "plugin-b", "pluginProtocolVersion": "1", "hooks": { "pre-process": { "command": "./bin/x" } } }
    """.write(to: tmpDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    try """
    { "values": {}, "rules": [] }
    """.write(to: tmpDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    try "bin".write(to: tmpDir.appendingPathComponent("x"), atomically: true, encoding: .utf8)

    #expect(throws: PackagerError.self) {
        try Packager.package(directory: tmpDir)
    }
}

@Test func packagerFailsOnMissingBinPath() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try """
    { "pluginName": "test", "pluginProtocolVersion": "1", "bin": ["nonexistent"], "data": [], "dependencies": [] }
    """.write(to: tmpDir.appendingPathComponent("piqley-build-manifest.json"), atomically: true, encoding: .utf8)

    try """
    { "name": "test", "pluginProtocolVersion": "1", "hooks": { "pre-process": { "command": "./bin/nonexistent" } } }
    """.write(to: tmpDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    try """
    { "values": {}, "rules": [] }
    """.write(to: tmpDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    #expect(throws: PackagerError.self) {
        try Packager.package(directory: tmpDir)
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter PackagerTests`
Expected: FAIL — `Packager` does not exist

- [ ] **Step 7: Implement Packager**

Create `piqley-plugin-sdk/swift/PiqleyPluginSDK/Packager.swift`:

```swift
import Foundation
import PiqleyCore

public enum PackagerError: Error, CustomStringConvertible {
    case missingBuildManifest
    case missingManifest
    case missingConfig
    case nameMismatch(buildManifest: String, manifest: String)
    case missingPath(String)
    case zipFailed(String)

    public var description: String {
        switch self {
        case .missingBuildManifest:
            return "piqley-build-manifest.json not found in project directory"
        case .missingManifest:
            return "manifest.json not found in project directory"
        case .missingConfig:
            return "config.json not found in project directory"
        case .nameMismatch(let bm, let m):
            return "pluginName mismatch: build manifest has '\(bm)', manifest.json has '\(m)'"
        case .missingPath(let path):
            return "Path does not exist: \(path)"
        case .zipFailed(let msg):
            return "Failed to create zip: \(msg)"
        }
    }
}

public struct Packager {
    /// Packages the plugin project at `directory` into a `.piqleyplugin` file.
    /// Returns the URL of the produced `.piqleyplugin` file.
    @discardableResult
    public static func package(directory: URL) throws -> URL {
        let fm = FileManager.default

        // 1. Read and decode build manifest
        let buildManifestURL = directory.appendingPathComponent("piqley-build-manifest.json")
        guard fm.fileExists(atPath: buildManifestURL.path) else {
            throw PackagerError.missingBuildManifest
        }
        let buildManifest = try BuildManifest.load(from: directory)

        // 2. Read and decode manifest.json
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw PackagerError.missingManifest
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        // 3. Read config.json
        let configURL = directory.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configURL.path) else {
            throw PackagerError.missingConfig
        }

        // 4. Verify name match
        guard buildManifest.pluginName == manifest.name else {
            throw PackagerError.nameMismatch(buildManifest: buildManifest.pluginName, manifest: manifest.name)
        }

        // 5. Verify all bin/data paths exist
        for path in buildManifest.bin + buildManifest.data {
            let fullPath = directory.appendingPathComponent(path)
            guard fm.fileExists(atPath: fullPath.path) else {
                throw PackagerError.missingPath(path)
            }
        }

        // 6. Assemble staging directory
        let stagingDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pluginDir = stagingDir.appendingPathComponent(buildManifest.pluginName)
        let binDir = pluginDir.appendingPathComponent("bin")
        let dataDir = pluginDir.appendingPathComponent("data")

        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Copy manifest.json and config.json
        try fm.copyItem(at: manifestURL, to: pluginDir.appendingPathComponent("manifest.json"))
        try fm.copyItem(at: configURL, to: pluginDir.appendingPathComponent("config.json"))

        // Copy bin entries
        for path in buildManifest.bin {
            let source = directory.appendingPathComponent(path)
            let dest = binDir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try fm.copyItem(at: source, to: dest)
        }

        // Copy data entries
        for path in buildManifest.data {
            let source = directory.appendingPathComponent(path)
            let dest = dataDir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try fm.copyItem(at: source, to: dest)
        }

        // 7. Create zip — zip the staging dir so the archive contains <plugin-name>/ as the root
        let outputURL = directory.appendingPathComponent("\(buildManifest.pluginName).piqleyplugin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pluginDir.path, outputURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PackagerError.zipFailed("ditto exited with status \(process.terminationStatus)")
        }

        // Cleanup staging
        try? fm.removeItem(at: stagingDir)

        return outputURL
    }
}
```

Note: `ditto` is macOS-specific. For cross-platform, consider using Foundation's `Archive` or a Swift zip library. For now, `ditto` matches the macOS-only target platform.

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test --filter PackagerTests`
Expected: All PASS

- [ ] **Step 9: Add piqley-build executable target**

In `piqley-plugin-sdk/Package.swift`, add an executable target:

```swift
.executableTarget(
    name: "piqley-build",
    dependencies: ["PiqleyPluginSDK"],
    path: "swift/PiqleyBuild"
),
```

Create `piqley-plugin-sdk/swift/PiqleyBuild/main.swift`:

```swift
import Foundation
import PiqleyPluginSDK

let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

do {
    let outputURL = try Packager.package(directory: directory)
    print("✓ Built \(outputURL.lastPathComponent)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
```

- [ ] **Step 10: Verify piqley-build compiles**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift build --target piqley-build`
Expected: Build succeeds

- [ ] **Step 11: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add swift/PiqleyPluginSDK/BuildManifest.swift swift/PiqleyPluginSDK/Packager.swift swift/PiqleyBuild/main.swift Package.swift swift/Tests/PackagerTests.swift
git commit -m "feat: add piqley-build CLI and Packager for .piqleyplugin packaging"
```

---

### Task 5: piqley-cli — InstallSubcommand

**Files:**
- Create: `piqley-cli/Sources/piqley/CLI/InstallCommand.swift`
- Modify: `piqley-cli/Sources/piqley/Constants/PluginDirectory.swift:1-3`
- Modify: `piqley-cli/Sources/piqley/CLI/PluginCommand.swift:11`
- Test: `piqley-cli/Tests/piqleyTests/InstallCommandTests.swift`

- [ ] **Step 1: Add `bin` constant to PluginDirectory**

In `piqley-cli/Sources/piqley/Constants/PluginDirectory.swift`, add:

```swift
static let bin = "bin"
```

So the file becomes:

```swift
enum PluginDirectory {
    static let bin = "bin"
    static let data = "data"
    static let logs = "logs"
}
```

- [ ] **Step 2: Write the failing test for InstallSubcommand**

Create `piqley-cli/Tests/piqleyTests/InstallCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import piqley

@Suite("InstallCommand")
struct InstallCommandTests {

    private func createTestPlugin(
        name: String,
        protocolVersion: String = "1",
        in directory: URL
    ) throws -> URL {
        let fm = FileManager.default
        let pluginDir = directory.appendingPathComponent(name)
        let binDir = pluginDir.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let manifest = """
        {
            "name": "\(name)",
            "pluginProtocolVersion": "\(protocolVersion)",
            "hooks": { "pre-process": { "command": "./bin/\(name)" } }
        }
        """
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let config = """
        { "values": {}, "rules": [] }
        """
        try config.write(to: pluginDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        try "#!/bin/sh".write(to: binDir.appendingPathComponent(name), atomically: true, encoding: .utf8)

        // Zip it — use --keepParent so the archive contains <name>/ as root directory
        let zipURL = directory.appendingPathComponent("\(name).piqleyplugin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pluginDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()

        // Clean up unzipped dir
        try fm.removeItem(at: pluginDir)

        return zipURL
    }

    @Test func installsValidPlugin() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "test-plugin", in: tmpDir)
        let pluginsDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try PluginInstaller.install(from: zipURL, to: pluginsDir)

        let installedDir = pluginsDir.appendingPathComponent("test-plugin")
        #expect(FileManager.default.fileExists(atPath: installedDir.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: installedDir.appendingPathComponent("config.json").path))
        #expect(FileManager.default.fileExists(atPath: installedDir.appendingPathComponent("bin/test-plugin").path))
        #expect(FileManager.default.fileExists(atPath: installedDir.appendingPathComponent("logs").path))
        #expect(FileManager.default.fileExists(atPath: installedDir.appendingPathComponent("data").path))
    }

    @Test func rejectsUnsupportedProtocolVersion() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "future-plugin", protocolVersion: "99", in: tmpDir)
        let pluginsDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: zipURL, to: pluginsDir)
        }
    }

    @Test func rejectsMissingManifest() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a zip with no manifest
        let emptyDir = tmpDir.appendingPathComponent("empty-plugin")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try "nothing".write(to: emptyDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let zipURL = tmpDir.appendingPathComponent("empty-plugin.piqleyplugin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", emptyDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()

        let pluginsDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: zipURL, to: pluginsDir)
        }
    }

    @Test func setsExecutablePermissions() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let zipURL = try createTestPlugin(name: "exec-test", in: tmpDir)
        let pluginsDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try PluginInstaller.install(from: zipURL, to: pluginsDir)

        let binPath = pluginsDir.appendingPathComponent("exec-test/bin/exec-test").path
        let attrs = try FileManager.default.attributesOfItem(atPath: binPath)
        let permissions = (attrs[.posixPermissions] as! NSNumber).intValue
        #expect(permissions & 0o111 != 0, "Binary should be executable")
    }

    @Test func rejectsCorruptedZip() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write random bytes with .piqleyplugin extension
        let zipURL = tmpDir.appendingPathComponent("bad.piqleyplugin")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: zipURL)

        let pluginsDir = tmpDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        #expect(throws: InstallError.self) {
            try PluginInstaller.install(from: zipURL, to: pluginsDir)
        }
    }
}
```

> **Note:** Dependency resolution (downloading `.piqleyplugin` URLs, cycle detection, duplicate handling) is deferred to a follow-up task. This plan implements single-package install only. The `PluginInstaller` does not resolve `manifest.json` `dependencies` entries — it installs the package as-is.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter InstallCommandTests`
Expected: FAIL — `PluginInstaller` and `InstallError` do not exist

- [ ] **Step 4: Implement PluginInstaller and InstallSubcommand**

Create `piqley-cli/Sources/piqley/CLI/InstallCommand.swift`:

```swift
import ArgumentParser
import Foundation
import PiqleyCore

enum InstallError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case notAPiqleyPlugin
    case missingManifest
    case invalidManifest(String)
    case unsupportedProtocolVersion(String, supported: Set<String>)
    case alreadyInstalled(String)
    case extractionFailed(String)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .notAPiqleyPlugin:
            return "File does not have .piqleyplugin extension"
        case .missingManifest:
            return "Package does not contain manifest.json"
        case .invalidManifest(let msg):
            return "Invalid manifest: \(msg)"
        case .unsupportedProtocolVersion(let v, let supported):
            return "Unsupported plugin protocol version '\(v)'. This CLI supports versions: \(supported.sorted().joined(separator: ", ")). Update piqley to install this plugin."
        case .alreadyInstalled(let name):
            return "Plugin '\(name)' is already installed. Use --force to overwrite."
        case .extractionFailed(let msg):
            return "Failed to extract package: \(msg)"
        }
    }
}

struct PluginInstaller {
    static let supportedProtocolVersions: Set<String> = ["1"]

    static func install(from zipURL: URL, to pluginsDirectory: URL, force: Bool = false) throws {
        let fm = FileManager.default

        // 1. Extract to temp directory
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, tmpDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw InstallError.extractionFailed("ditto exited with status \(process.terminationStatus)")
        }

        // 2. Find the plugin directory (first directory in extracted contents)
        let contents = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: [.isDirectoryKey])
        guard let pluginDir = contents.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) else {
            throw InstallError.missingManifest
        }

        // 3. Read and validate manifest
        let manifestURL = pluginDir.appendingPathComponent(PluginFile.manifest)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw InstallError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        } catch {
            throw InstallError.invalidManifest(error.localizedDescription)
        }

        // 4. Validate protocol version
        guard supportedProtocolVersions.contains(manifest.pluginProtocolVersion) else {
            throw InstallError.unsupportedProtocolVersion(
                manifest.pluginProtocolVersion,
                supported: supportedProtocolVersions
            )
        }

        // 5. Check ManifestValidator
        let errors = ManifestValidator.validate(manifest)
        if !errors.isEmpty {
            throw InstallError.invalidManifest(errors.joined(separator: "; "))
        }

        // 6. Check if already installed
        let installDir = pluginsDirectory.appendingPathComponent(manifest.name)
        if fm.fileExists(atPath: installDir.path) {
            if force {
                try fm.removeItem(at: installDir)
            } else {
                throw InstallError.alreadyInstalled(manifest.name)
            }
        }

        // 7. Move to plugins directory
        try fm.moveItem(at: pluginDir, to: installDir)

        // 8. Set executable permissions on bin/ contents
        let binDir = installDir.appendingPathComponent(PluginDirectory.bin)
        if fm.fileExists(atPath: binDir.path) {
            if let enumerator = fm.enumerator(at: binDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    if resourceValues.isRegularFile == true {
                        var attrs = try fm.attributesOfItem(atPath: fileURL.path)
                        let currentPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                        try fm.setAttributes(
                            [.posixPermissions: currentPerms | 0o111],
                            ofItemAtPath: fileURL.path
                        )
                    }
                }
            }
        }

        // 9. Create logs/ and data/ if not present
        let logsDir = installDir.appendingPathComponent(PluginDirectory.logs)
        let dataDir = installDir.appendingPathComponent(PluginDirectory.data)
        if !fm.fileExists(atPath: logsDir.path) {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: dataDir.path) {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }
    }
}

struct InstallSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a plugin from a .piqleyplugin file"
    )

    @Argument(help: "Path to .piqleyplugin file")
    var pluginFile: String

    @Flag(help: "Overwrite if already installed")
    var force = false

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: pluginFile)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw InstallError.fileNotFound(pluginFile)
        }

        guard fileURL.pathExtension == "piqleyplugin" else {
            throw InstallError.notAPiqleyPlugin
        }

        let pluginsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/piqley/plugins")

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try PluginInstaller.install(from: fileURL, to: pluginsDir, force: force)

        print("✓ Plugin installed successfully")
    }
}
```

- [ ] **Step 5: Register InstallSubcommand in PluginCommand**

In `piqley-cli/Sources/piqley/CLI/PluginCommand.swift` line 11, add `InstallSubcommand` to the subcommands array:

From: `subcommands: [SetupSubcommand.self, InitSubcommand.self, CreateSubcommand.self, ConfigSubcommand.self]`
To: `subcommands: [SetupSubcommand.self, InitSubcommand.self, CreateSubcommand.self, ConfigSubcommand.self, InstallSubcommand.self]`

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter InstallCommandTests`
Expected: All PASS

- [ ] **Step 7: Run all CLI tests**

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test`
Expected: All PASS

- [ ] **Step 8: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-cli
git add Sources/piqley/CLI/InstallCommand.swift Sources/piqley/Constants/PluginDirectory.swift Sources/piqley/CLI/PluginCommand.swift Tests/piqleyTests/InstallCommandTests.swift
git commit -m "feat: add piqley plugin install command for .piqleyplugin files"
```

---

### Task 6: Swift Skeleton — Build Manifest Template

**Files:**
- Create: `piqley-plugin-sdk/Skeletons/swift/piqley-build-manifest.json`

- [ ] **Step 1: Create the template file**

Create `piqley-plugin-sdk/Skeletons/swift/piqley-build-manifest.json`:

```json
{
  "pluginName": "__PLUGIN_NAME__",
  "pluginProtocolVersion": "1",
  "bin": [".build/release/__PLUGIN_NAME__"],
  "data": [],
  "dependencies": []
}
```

- [ ] **Step 2: Verify template substitution works**

The existing `SkeletonFetcher` at `piqley-cli/Sources/piqley/CLI/SkeletonFetcher.swift` already replaces `__PLUGIN_NAME__` in all files. Verify this by checking that `piqley-build-manifest.json` is not excluded from template substitution.

Run: `cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test --filter Create`
Expected: Existing create tests still pass

- [ ] **Step 3: Commit**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk
git add Skeletons/swift/piqley-build-manifest.json
git commit -m "feat: add piqley-build-manifest.json template to Swift skeleton"
```

---

### Task 7: Integration Verification

- [ ] **Step 1: Run full test suite across all repos**

```bash
cd /Users/wash/Developer/tools/piqley/piqley-core && swift test
cd /Users/wash/Developer/tools/piqley/piqley-plugin-sdk && swift test
cd /Users/wash/Developer/tools/piqley/piqley-cli && swift test
```

Expected: All PASS

- [ ] **Step 2: Manual end-to-end test**

In a temp directory, create a test plugin project and verify the full flow:

```bash
# Create a plugin project
mkdir /tmp/test-piqley-plugin && cd /tmp/test-piqley-plugin

# Write manifest.json, config.json, piqley-build-manifest.json, and a fake binary
# Run: swift run piqley-build (from the SDK)
# Verify: test-piqley-plugin.piqleyplugin is created
# Run: piqley plugin install test-piqley-plugin.piqleyplugin
# Verify: plugin appears in ~/.config/piqley/plugins/
```

- [ ] **Step 3: Verify the created .piqleyplugin structure**

Unzip the `.piqleyplugin` file and verify:
- Contains `<plugin-name>/manifest.json`
- Contains `<plugin-name>/config.json`
- Contains `<plugin-name>/bin/<binary>`
- Binary has executable permissions
