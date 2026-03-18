# piqley — Architecture Guidelines

## No Magic Strings

String literals used as keys, identifiers, or lookup values **must not** appear inline. Extract them into caseless enums with `static let` constants in `Sources/piqley/Constants/`.

### What counts as a magic string

- Environment variable names (`PIQLEY_FOLDER_PATH`, `PIQLEY_HOOK`, …)
- Environment variable prefixes (`PIQLEY_SECRET_`, `PIQLEY_CONFIG_`)
- Config and data file paths (`.config/piqley/config.json`, `manifest.json`, …)
- Plugin directory names (`data`, `logs`)
- Reserved identifiers (`original`, `pre-process`)
- Secret key prefixes and namespaces (`piqley.plugins.`)
- Pattern directive prefixes (`regex:`, `glob:`)

### Pattern

Use **caseless enums** with `static let` constants. This avoids `.rawValue` at call sites and prevents accidental instantiation:

```swift
enum PluginEnvironment {
    static let folderPath = "PIQLEY_FOLDER_PATH"
    static let hook = "PIQLEY_HOOK"
    static let dryRun = "PIQLEY_DRY_RUN"
    static let execLogPath = "PIQLEY_EXECUTION_LOG_PATH"
    static let imagePath = "PIQLEY_IMAGE_PATH"
    static let secretPrefix = "PIQLEY_SECRET_"
    static let configPrefix = "PIQLEY_CONFIG_"
}
```

Group related constants by domain — one enum per file. Place them in the **lowest package** that needs them:

**PiqleyCore** (shared across CLI and Plugin SDK):

| Domain | Enum | Location |
|--------|------|----------|
| Plugin filenames | `PluginFile` | `PiqleyCore/Constants/PluginFile.swift` |
| Reserved identifiers | `ReservedName` | `PiqleyCore/Constants/ReservedName.swift` |
| Pattern prefixes | `PatternPrefix` | `PiqleyCore/Constants/PatternPrefix.swift` |
| Hook stages | `Hook` | `PiqleyCore/Hook.swift` (String-backed enum with cases) |

**piqley-cli** (CLI-only constants):

| Domain | Enum | Location |
|--------|------|----------|
| Environment variables | `PluginEnvironment` | `Sources/piqley/Constants/PluginEnvironment.swift` |
| Filesystem paths | `PiqleyPath` | `Sources/piqley/Constants/PiqleyPath.swift` |
| Plugin directories | `PluginDirectory` | `Sources/piqley/Constants/PluginDirectory.swift` |
| Secret namespacing | `SecretNamespace` | `Sources/piqley/Constants/SecretNamespace.swift` |

### Rules

1. **Never introduce a new string key inline.** Add it to the appropriate enum first.
2. **Caseless enums with `static let`** — no cases, no `.rawValue`, no instantiation.
3. **One enum per domain** — keep them small and co-located with the code that uses them most.
4. **If a string appears in two or more files, it must be a constant.** No exceptions.
5. **Avoid naming collisions with system frameworks** (e.g. don't use `EnvironmentKey` — SwiftUI owns that).
