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

### 5. Modified: `MetadataExtractor.swift`

Wrap the entire file in `#if canImport(ImageIO)` / `#endif`. ImageIO is unavailable on Linux.

Add a Linux stub that returns an empty dictionary — metadata extraction from EXIF/IPTC is macOS-only for now. The "original" state namespace will be empty on Linux, which is acceptable since plugins can still function without it.

### 6. Factory Function for SecretStore Construction

Add a `makeDefaultSecretStore()` factory function in `SecretStore.swift` to centralize platform branching:

```swift
func makeDefaultSecretStore() -> any SecretStore {
    #if os(macOS)
    KeychainSecretStore()
    #else
    FileSecretStore()
    #endif
}
```

Replace all 5 `KeychainSecretStore()` call sites across 4 files with `makeDefaultSecretStore()`:
- `ProcessCommand.swift` (line 43)
- `SetupCommand.swift` (line 57)
- `SecretCommand.swift` (lines 28, 47)
- `PluginCommand.swift` (line 36)

### 7. Modified: `ProcessLock.swift`

Replace `(path as NSString).deletingLastPathComponent` with URL-based path manipulation to avoid the NSString Objective-C bridge, which behaves differently on Linux.

### 8. Modified: `TempFolder.swift`

Replace `NSTemporaryDirectory()` with `FileManager.default.temporaryDirectory` for cross-platform compatibility.

### 9. Modified: `SecretStore.swift`

**Error enum changes:**
- Replace `OSStatus` in `SecretStoreError.unexpectedError(status: OSStatus)` with `Int32` (which `OSStatus` aliases on Darwin). This allows the shared error enum to compile on Linux.
- Make error description strings platform-conditional:
  - macOS: "Keychain secret not found", "Check Keychain Access.app"
  - Linux: "Secret not found", "Check ~/.config/piqley/secrets.json"

### 10. Modified: `SecretCommand.swift`

Platform-conditional help text:
- macOS: references "macOS Keychain"
- Linux: references "secrets file (~/.config/piqley/secrets.json)"

### 11. Modified: `PipelineOrchestrator.swift`

Update comment on line 100 and log message on line 206 to use generic "secret store" instead of "Keychain".

### 12. Modified: `TestHelpers.swift`

Wrap the CoreGraphics/ImageIO test JPEG generator in `#if os(macOS)`. On Linux, tests load the static JPEG fixture from `Tests/piqleyTests/Fixtures/` instead.

### 13. Modified: `MetadataExtractorTests.swift`

Wrap entire test file in `#if canImport(ImageIO)` since the tests exercise CoreGraphics/ImageIO APIs that are unavailable on Linux.

## What Does NOT Change

- **PluginRunner.swift** — `Process`, `Pipe`, `FileHandle` work on Linux
- **PluginSetupScanner.swift** — `FileManager.isExecutableFile()` works on Linux (executable bit exists)
- **Config.swift** — `~/.config/piqley/` follows XDG convention, correct for Linux
- **Dependencies** — swift-argument-parser and swift-log are fully cross-platform
- **CI** — no Linux CI job added (out of scope)

## Risk Notes

- The plain-text secrets file is less secure than Keychain. This is an accepted trade-off, consistent with how many CLI tools (gh, docker) handle credentials on Linux.
- `flock()` in ProcessLock works on both macOS and Linux with the same semantics for the non-blocking exclusive lock pattern used here. No changes needed to the locking mechanism itself.
- Metadata extraction (EXIF/IPTC) is macOS-only. On Linux, the "original" state namespace will be empty. This is acceptable for now; a future enhancement could shell out to `exiftool` on Linux.
- `NSTemporaryDirectory()` actually works on Linux via swift-corelibs-foundation, but `FileManager.default.temporaryDirectory` is the more idiomatic API.
