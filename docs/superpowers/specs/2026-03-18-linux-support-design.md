# Linux Support Design

**Date:** 2026-03-18
**Status:** Approved

## Goal

Make piqley build and run on Linux (in addition to macOS). Windows is out of scope.

## Decisions

- **Secret storage on Linux:** Plain-text JSON file with `0600` permissions at `~/.config/piqley/secrets.json`
- **Architecture:** Platform-specific implementations behind existing protocols, with `#if os()` only at construction points
- **Test fixtures:** Static JPEG file committed to repo for Linux (CoreGraphics/ImageIO unavailable)
- **CI:** Linux CI is out of scope for this change

## Changes

### 1. New File: `FileSecretStore.swift`

A `SecretStore` implementation for Linux that persists secrets as a JSON dictionary to `~/.config/piqley/secrets.json`.

**Behavior:**
- `get(key:)` — reads file, decodes JSON `[String: String]`, returns value or throws `.notFound`
- `set(key:value:)` — reads file (or starts with empty dict), upserts key, writes back with `0600` permissions
- `delete(key:)` — reads file, removes key, writes back

**File permissions:** Created with POSIX mode `0o600` (owner read/write only). Permissions are set on every write to ensure they remain correct.

**Location:** `Sources/piqley/Secrets/FileSecretStore.swift`

### 2. New File: Static Test JPEG Fixture

A minimal valid JPEG file committed to `Tests/piqleyTests/Fixtures/` for use on Linux where CoreGraphics/ImageIO are unavailable.

### 3. Modified: `Package.swift`

Remove `platforms: [.macOS(.v13)]` to allow building on Linux. The macOS deployment target will fall back to the toolchain default, which is acceptable for a CLI tool.

### 4. Modified: `KeychainSecretStore.swift`

Wrap the entire file contents in `#if os(macOS)` / `#endif` so it does not compile on Linux (the `Security` framework is unavailable).

### 5. Modified: `Piqley.swift`

Platform-conditional `SecretStore` construction at the point where the store is created:

```swift
#if os(macOS)
let secretStore: SecretStore = KeychainSecretStore()
#else
let secretStore: SecretStore = FileSecretStore()
#endif
```

### 6. Modified: `ProcessLock.swift`

Replace `(path as NSString).deletingLastPathComponent` with URL-based path manipulation to avoid the NSString Objective-C bridge, which behaves differently on Linux.

### 7. Modified: `TempFolder.swift`

Replace `NSTemporaryDirectory()` with `FileManager.default.temporaryDirectory` for cross-platform compatibility.

### 8. Modified: `SecretCommand.swift` and `SecretStore.swift`

Platform-conditional user-facing strings:
- macOS: references "macOS Keychain"
- Linux: references "secrets file (~/.config/piqley/secrets.json)"

### 9. Modified: `TestHelpers.swift`

Wrap the CoreGraphics/ImageIO test JPEG generator in `#if os(macOS)`. On Linux, tests load the static JPEG fixture from `Tests/piqleyTests/Fixtures/` instead.

## What Does NOT Change

- **PluginRunner.swift** — `Process`, `Pipe`, `FileHandle` work on Linux
- **PluginSetupScanner.swift** — `FileManager.isExecutableFile()` works on Linux (executable bit exists)
- **Config.swift** — `~/.config/piqley/` follows XDG convention, correct for Linux
- **Dependencies** — swift-argument-parser and swift-log are fully cross-platform
- **CI** — no Linux CI job added (out of scope)

## Risk Notes

- The plain-text secrets file is less secure than Keychain. This is an accepted trade-off, consistent with how many CLI tools (gh, docker) handle credentials on Linux.
- `flock()` in ProcessLock works on both macOS and Linux with the same semantics for the non-blocking exclusive lock pattern used here. No changes needed to the locking mechanism itself.
