# Config Entry Labels and Descriptions

**Date:** 2026-03-26
**Status:** Draft

## Problem

During plugin installation/setup, the CLI shows raw field names (e.g. `BASE_API`, `ADMIN_API_KEY`) to the user. These are developer-facing identifiers, not user-friendly. Plugin authors need a way to provide human-readable labels and optional descriptions for their config entries and secrets.

## Design

### Approach: ConfigMetadata struct (Approach B)

A new `ConfigMetadata` struct groups display-related fields, added as a parameter to each `ConfigEntry` enum case. The JSON manifest stays flat (label/description sit alongside key/type), but Swift groups them internally.

### 1. piqley-core: ConfigEntry.swift

**New struct** (same file or adjacent):

```swift
public struct ConfigMetadata: Codable, Sendable, Equatable {
    public let label: String?
    public let description: String?

    public init(label: String? = nil, description: String? = nil) {
        self.label = label
        self.description = description
    }
}
```

**Updated enum cases:**

```swift
public enum ConfigEntry: Codable, Sendable, Equatable {
    case value(key: String, type: ConfigValueType, value: JSONValue, metadata: ConfigMetadata)
    case secret(secretKey: String, type: ConfigValueType, metadata: ConfigMetadata)
}
```

**Decoding:** After parsing key/secret_key and type from the flat JSON container, decode `label` and `description` as optional strings from the same container, then construct `ConfigMetadata`. No nesting in JSON.

**Encoding:** Encode `label` and `description` back into the flat container alongside the other fields. Only encode when non-nil.

**New CodingKeys:** Add `.label` and `.description` to the existing `CodingKeys` enum.

**Convenience property on ConfigEntry:**

```swift
public var displayLabel: String {
    switch self {
    case .value(let key, _, _, let metadata):
        return (metadata.label?.isEmpty == false) ? metadata.label! : key
    case .secret(let secretKey, _, let metadata):
        return (metadata.label?.isEmpty == false) ? metadata.label! : secretKey
    }
}
```

### 2. piqley-plugin-sdk: manifest.schema.json

Both `configEntry` variants in the `oneOf` get optional `label` and `description` string properties. Neither is added to `required`.

Value entry variant:

```json
{
  "type": "object",
  "required": ["key", "type"],
  "properties": {
    "key": { "type": "string" },
    "type": { "enum": ["string", "int", "float", "bool"] },
    "value": {},
    "label": { "type": "string" },
    "description": { "type": "string" }
  },
  "additionalProperties": false
}
```

Secret entry variant:

```json
{
  "type": "object",
  "required": ["secret_key", "type"],
  "properties": {
    "secret_key": { "type": "string" },
    "type": { "enum": ["string", "int", "float", "bool"] },
    "label": { "type": "string" },
    "description": { "type": "string" }
  },
  "additionalProperties": false
}
```

Existing manifests without label/description remain valid.

### 3. piqley-cli: PluginSetupScanner.swift

**promptForValue and promptForSecret** use `entry.displayLabel` instead of the raw key. When `metadata.description` is non-nil and non-empty, print it on a preceding line (indented with two spaces).

Example output with label and description:

```
  Found under Settings > General in your Ghost admin panel
  [Ghost CMS Publisher] Site URL [https://example.com]:
```

Example output with label only:

```
  [Ghost CMS Publisher] Site URL [https://example.com]:
```

Example output with no label (fallback to key):

```
  [Ghost CMS Publisher] BASE_URL [https://example.com]:
```

**"Already set" messages** also use displayLabel:

```
  [Ghost CMS Publisher] Site URL already set to: https://example.com
  [Ghost CMS Publisher] Ghost Admin API Key (secret) already set
```

Method signatures update to accept the `ConfigEntry` directly instead of decomposed parameters, so they can access both the key and metadata.

## Repos affected

| Repo | Files | Change |
|------|-------|--------|
| piqley-core | `ConfigEntry.swift` | Add `ConfigMetadata` struct, update enum cases, decoding/encoding, add `displayLabel` |
| piqley-plugin-sdk | `manifest.schema.json` | Add optional `label` and `description` to both configEntry variants |
| piqley-cli | `PluginSetupScanner.swift` | Use `displayLabel` and show `description` in prompts |

## Testing

- **piqley-core:** Update existing `ConfigEntry` decode/encode tests to include `metadata` parameter. Add cases for: label present, label missing, label empty string (falls back to key), description present, description missing. Verify `displayLabel` computed property.
- **piqley-cli:** Update `PluginSetupScanner` tests to verify label and description appear in prompt output. Add cases for entries with and without metadata.

## Backwards compatibility

- `label` and `description` are optional in both the JSON schema and Swift model
- Existing manifests without these fields parse and validate without changes
- The CLI falls back to the raw key name when label is missing or empty
