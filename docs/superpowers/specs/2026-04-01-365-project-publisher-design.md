# 365 Project Publisher Plugin + Fingerprinting Extraction

**Date:** 2026-04-01
**Status:** Draft

## Overview

Two pieces of work:

1. **Extract the Fingerprinting module** from the Ghost CMS plugin into piqley-plugin-sdk as a reusable library product.
2. **Create a new plugin** (`photo.quigs.365-project-publisher`) that emails images from the 365 project via SMTP, reusing the shared Fingerprinting module for deduplication.

## Part 1: Fingerprinting Extraction to piqley-plugin-sdk

### What Moves

The 5 source files and 4 test files from `plugins/photo.quigs.ghostcms.publisher/Sources/Fingerprinting/` and `Tests/FingerprintTests/`:

**Sources:**
- `DCT.swift` — 1D and 2D Discrete Cosine Transform
- `PHash.swift` — Perceptual hashing (32x32 grayscale → 64-bit hash via DCT)
- `ImageFingerprint.swift` — Hash container with Hamming distance calculation
- `ImageFingerprinter.swift` — Protocol + `PerceptualFingerprinter` (CoreGraphics) and `FilenameFingerprinter` (fallback)
- `UploadCache.swift` — JSON-based deduplication cache with fuzzy matching

**Tests:**
- `DCTTests.swift`
- `PHashTests.swift`
- `ImageFingerprintTests.swift`
- `UploadCacheTests.swift`

### SDK Changes

New directories:
- `swift/Fingerprinting/` — source files
- `swift/Tests/FingerprintingTests/` — test files

`Package.swift` additions:
- New library product: `Fingerprinting`
- New target: `Fingerprinting` with `path: "swift/Fingerprinting"`, zero dependencies (pure Swift + CoreGraphics)
- New test target: `FingerprintingTests` depending on `Fingerprinting`

SDK version bump (minor) — additive change, no breaking API modifications.

### Ghost Plugin Changes

- Delete `Sources/Fingerprinting/` and `Tests/FingerprintTests/` directories
- Remove the `Fingerprinting` and `FingerprintTests` targets from `Package.swift`
- Replace local target dependency with `.product(name: "Fingerprinting", package: "piqley-plugin-sdk")`
- No source code changes needed — `import Fingerprinting` statements remain valid

## Part 2: 365 Project Publisher Plugin

### Identity

- **Namespace:** `photo.quigs.365-project-publisher`
- **Plugin name:** 365 Project Publisher
- **Binary name:** `365-project-publisher`

### Directory Layout

```
plugins/photo.quigs.365-project-publisher/
├── Package.swift
├── piqley-build-manifest.json
├── Sources/
│   ├── PluginHooks/
│   │   ├── Hooks.swift
│   │   └── ProjectField.swift
│   ├── 365-project-publisher/
│   │   ├── main.swift
│   │   ├── Plugin.swift
│   │   ├── EmailSender.swift
│   │   └── Constants.swift
│   └── ManifestGen/
│       └── main.swift
└── Tests/
    └── PluginTests/
```

### Dependencies

- `piqley-plugin-sdk` — for `PiqleyPluginSDK` and `Fingerprinting` library products
- `Kitura/Swift-SMTP` (v6.0.0+) — SMTP client (same library as old `_migrate/Email/EmailSender.swift`)

### State Fields

Namespace: `photo.quigs.365-project-publisher`

| Field | Type | Description |
|-------|------|-------------|
| `recipient` | string | Email address to send to |
| `subject` | string | Email subject line |
| `body` | string | Email body text (plain text, allowed to be empty) |
| `is_ignored` | bool | Skip this image |

### Config Entries

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `SMTP_HOST` | string | `""` | SMTP server hostname |
| `SMTP_PORT` | int | `587` | SMTP server port |
| `SMTP_USERNAME` | string | `""` | SMTP username |
| `SMTP_FROM` | string | `""` | Sender email address |
| `SMTP_PASSWORD` | secret | — | SMTP password via SecretStore |
| `FINGERPRINT_SENSITIVITY` | string | `"moderate"` | Perceptual hash sensitivity: conservative, moderate, or aggressive |

### Hook Registration

Registers at the `publish` stage only. All other `StandardHook` cases return `nil`.

### Publish Flow

Per-image, sequential:

1. **Fingerprint** the image via `PerceptualFingerprinter` (fallback to `FilenameFingerprinter` on non-macOS)
2. **Check UploadCache** — if perceptual match found within sensitivity threshold, skip and report
3. **Check `is_ignored`** — if `"true"`, skip with warning
4. **Read state fields** — `recipient`, `subject`, `body` from plugin namespace
5. **Validate** — `recipient` and `subject` must be present and non-empty (fail the image if missing)
6. **Send email** via SMTP with:
   - Sender: `SMTP_FROM` config value
   - Recipient: state field value
   - Subject: state field value
   - Body: state field value (empty string if not set)
   - Attachment: the image file as `image/jpeg`
   - Encryption: STARTTLS (matching old implementation)
7. **Update UploadCache** — store hash, filename, and `"sent"` as the cache value
8. **Report result** — success or failure per image

### EmailSender

Adapted from `piqley-cli/_migrate/Email/EmailSender.swift`. Key differences from the old code:

- Reads SMTP config from plugin config entries (not `AppConfig.SMTPConfig`)
- Reads password from plugin secrets (not a standalone `SecretStore`)
- Same SwiftSMTP API: `Configuration`, `Email`, `Mailer`
- Same STARTTLS encryption with ESMTP feature flag

### Constants

Central namespace for string constants:
- `ConfigKey` — SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_FROM, SMTP_PASSWORD, FINGERPRINT_SENSITIVITY
- `MIMEType` — image/jpeg (primary)
- Sensitivity thresholds — reuse same values as ghost (conservative: 5, moderate: 10, aggressive: 18) via `Fingerprinting.UploadCache` threshold parameter

### Build Manifest

```json
{
  "identifier": "photo.quigs.365-project-publisher",
  "pluginName": "365 Project Publisher",
  "pluginSchemaVersion": "1",
  "type": "static",
  "pluginVersion": "0.1.0",
  "bin": {
    "macos-arm64": [".build/arm64-apple-macosx/release/365-project-publisher"]
  },
  "data": {},
  "dependencies": []
}
```

## Testing

### Fingerprinting (SDK)

Existing tests move as-is. All 4 test files must pass in the new location with `@testable import Fingerprinting`.

### Ghost Plugin

After extraction, `swift build` and `swift test` must pass with the Fingerprinting dependency now coming from the SDK.

### 365 Plugin

- `swift build` must succeed
- `piqley-manifest-gen` must produce valid stage/config/field JSON files
- Manual integration test: configure SMTP credentials and send a test image
