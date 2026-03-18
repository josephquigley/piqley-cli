# piqley — Architecture Guidelines

## No Magic Strings

String literals used as keys, identifiers, or lookup values **must not** appear inline. Extract them into dedicated `enum` types — use `String`-backed enums when the raw value matters (e.g. environment variable names, JSON keys, file paths).

### What counts as a magic string

- Environment variable names (`PIQLEY_FOLDER_PATH`, `PIQLEY_HOOK`, …)
- Environment variable prefixes (`PIQLEY_SECRET_`, `PIQLEY_CONFIG_`)
- Config and data file paths (`.config/piqley/config.json`, `manifest.json`, …)
- Plugin directory names (`data`, `logs`)
- Reserved identifiers (`original`, `pre-process`)
- Secret key prefixes and namespaces (`piqley.plugins.`)
- Pattern directive prefixes (`regex:`, `glob:`)

### How to fix

Prefer a `String`-backed enum when values are used for serialization, environment, or filesystem lookup:

```swift
enum EnvironmentKey: String {
    case folderPath   = "PIQLEY_FOLDER_PATH"
    case hook         = "PIQLEY_HOOK"
    case dryRun       = "PIQLEY_DRY_RUN"
    case execLogPath  = "PIQLEY_EXECUTION_LOG_PATH"
    case imagePath    = "PIQLEY_IMAGE_PATH"
}
```

Use a plain enum with static properties when the values are constructed or prefixed:

```swift
enum EnvironmentPrefix {
    static let secret = "PIQLEY_SECRET_"
    static let config = "PIQLEY_CONFIG_"
}
```

Group related constants by domain — not in one catch-all `Constants` file:

| Domain | Enum / Type | Location |
|--------|-------------|----------|
| Environment variables | `EnvironmentKey`, `EnvironmentPrefix` | `Sources/piqley/Constants/EnvironmentKey.swift` |
| Filesystem paths | `PiqleyPath` | `Sources/piqley/Constants/PiqleyPath.swift` |
| Plugin filenames & dirs | `PluginFile`, `PluginDirectory` | `Sources/piqley/Constants/PluginFile.swift` |
| Reserved names & hooks | `ReservedName`, `HookName` | `Sources/piqley/Constants/ReservedName.swift` |
| Secret namespacing | `SecretNamespace` | `Sources/piqley/Constants/SecretNamespace.swift` |

### Rules

1. **Never introduce a new string key inline.** Add it to the appropriate enum first.
2. **Prefer `enum` over `struct` with static lets** — enums without cases cannot be accidentally instantiated.
3. **One enum per domain** — keep them small and co-located with the code that uses them most.
4. **If a string appears in two or more files, it must be a constant.** No exceptions.
5. **Raw values must match the actual string exactly** — no transformations at call sites.
