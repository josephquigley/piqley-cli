# Cryptographic Image Signing — Design Spec

## Overview

Add GPG-based cryptographic signing to `quigsphoto-uploader`. After resizing, the tool signs a deterministic content hash of each image and embeds the signature in a custom XMP namespace. A new `verify` subcommand allows anyone with the signer's public key to verify image integrity and authorship.

**Goals:**
- **Tamper detection (integrity):** Verify an image hasn't been modified since signing
- **Authorship attribution:** Prove a specific GPG key owner signed the image

**Scope:** Sign the uploaded original only. Ghost's responsive image variants (generated server-side by Sharp) are unsigned. To verify an image from Ghost, download the original (strip `/size/wXXX/` from the variant URL) and run `quigsphoto verify` on the local file.

## Approach: Content Hash Signing

The core challenge is that embedding a signature in XMP modifies the file, invalidating a whole-file hash. The solution: sign a deterministic "signable content" hash that excludes the signature XMP namespace. Both signing and verification extract the same content, so the hash is stable.

### Signable Content Extraction

The signing pipeline uses a two-phase approach:

**Phase 1 (Signing):** Hash the complete file bytes of the resized JPEG *before* any XMP signing fields are added. This is the simplest and most robust approach — the file hasn't been modified, so the hash covers exactly what was produced by the image processor.

**Phase 2 (Embedding):** Write XMP signing fields (hash, signature, fingerprint, algorithm) into the image. The file now differs from what was hashed, but that's expected.

**Verification:** Read the XMP signing fields, then reconstruct the pre-signing file by stripping those fields and re-writing the image without them. Hash the result and compare.

The shared `SignableContentExtractor` handles both directions:
- `hashFile(at:)` — SHA-256 of the raw file bytes (used during signing, before XMP injection)
- `hashFileStrippingSignature(at:namespace:prefix:)` — strip XMP signing fields, re-write to temp file, hash the result (used during verification)

## Signing Pipeline

Slots into the existing pipeline between resize and upload:

```
Scan → Dedup → Resize → **Sign** → Upload → Email
```

### Steps

1. `SignableContentExtractor` computes the SHA-256 content hash of the resized JPEG
2. Shell out to `gpg --detach-sign --armor -u <fingerprint>` with the hash as stdin
3. Write custom XMP fields to the image via `CGImageDestination`:
   - `quigsphoto:contentHash` — SHA-256 hex string
   - `quigsphoto:signature` — ASCII-armored GPG detached signature
   - `quigsphoto:keyFingerprint` — signing key fingerprint
   - `quigsphoto:algorithm` — `"GPG-SHA256"`
4. The signed JPEG (with XMP) replaces the unsigned version in the temp directory
5. Upload proceeds as normal

### Error Handling

Signing failures are **fatal** — the tool exits with code 1. Rationale: if signing is configured, silently publishing unsigned images defeats the purpose. The user must fix the issue (missing key, gpg not installed) or use `--no-sign` to explicitly opt out.

## Verification Subcommand

```
quigsphoto verify <image-path> [--key-fingerprint <fp>]
```

### Steps

1. Read XMP fields (`quigsphoto:contentHash`, `quigsphoto:signature`, `quigsphoto:keyFingerprint`). Fail with a clear message if no signature is found.
2. Extract signable content using `SignableContentExtractor` (same logic as signing)
3. Recompute SHA-256 over the extracted content
4. Compare recomputed hash against `quigsphoto:contentHash`. Mismatch → image tampered.
5. Shell out to `gpg --verify` with the embedded signature and the hash
6. Report results:
   - **Signed by:** key fingerprint / UID (if available)
   - **Content integrity:** `PASS` or `FAIL`
   - **Signature validity:** `VALID`, `INVALID`, or `UNKNOWN KEY`

The `--key-fingerprint` flag is optional. If omitted, GPG checks against the local keyring. If provided, additionally confirms the signature was made by that specific key.

## Configuration

### Config File Addition

```json
{
  "signing": {
    "keyFingerprint": "ABCD1234...",
    "xmpNamespace": "http://quigs.photo/xmp/1.0/",
    "xmpPrefix": "quigsphoto"
  }
}
```

- `xmpNamespace` and `xmpPrefix` default to `"http://quigs.photo/xmp/1.0/"` and `"quigsphoto"` if omitted. Configurable for forks that want their own branding. Field names (`contentHash`, `signature`, `keyFingerprint`, `algorithm`) are fixed.

**Behavior:**
- If `signing` section is present → signing is enabled (always-on)
- `--no-sign` flag on `process` subcommand → skip signing for this run
- No `signing` section → signing is disabled, `--no-sign` is a no-op

The `enabled` field is not needed — presence of the section implies enabled, and `--no-sign` handles the opt-out case.

### Setup Integration

`quigsphoto setup` gains an optional signing section:

1. "Do you want to enable image signing? (y/n)"
2. If yes, run `gpg --list-secret-keys --keyid-format long` and display available keys
3. User selects a key by fingerprint
4. Validate the key exists, write fingerprint to config

## CLI Changes

### `process` subcommand

New flag:
- `--no-sign` — skip signing for this run, even if configured

### `verify` subcommand (new)

```
quigsphoto verify <image-path> [--key-fingerprint <fp>]
```

Arguments:
- `<image-path>` — path to a JPEG file to verify (required)
- `--key-fingerprint <fp>` — assert the signature was made by this specific key (optional)

Exit codes:
- 0: signature valid, content integrity passes
- 1: signature invalid, content tampered, key not found, or no signature present

## XMP Namespace

Namespace and prefix are configurable (see Configuration). Defaults:
- Namespace: `http://quigs.photo/xmp/1.0/`
- Prefix: `quigsphoto`

Field names are fixed (not configurable):

| Field | Type | Description |
|-------|------|-------------|
| `<prefix>:contentHash` | string | SHA-256 hex of signable content |
| `<prefix>:signature` | string | ASCII-armored GPG detached signature |
| `<prefix>:keyFingerprint` | string | Full fingerprint of the signing key |
| `<prefix>:algorithm` | string | `"GPG-SHA256"` |

The `verify` command reads the namespace/prefix from config (or uses defaults) to locate the correct XMP fields.

## Architecture

### New Files

Following the existing protocol-first, one-type-per-file convention:

```
Sources/quigsphoto-uploader/
├── ImageProcessing/
│   ├── ImageSigner.swift              (protocol)
│   ├── GPGImageSigner.swift           (implementation: gpg shelling, XMP writing)
│   └── SignableContentExtractor.swift (deterministic content extraction + hashing)
├── CLI/
│   └── VerifyCommand.swift            (verify subcommand)
```

### Protocols

```swift
struct SigningResult {
    let contentHash: String
    let signature: String
    let keyFingerprint: String
}

protocol ImageSigner {
    func sign(imageAt path: String) async throws -> SigningResult
}
```

### Integration Point

In `ProcessCommand.swift`, after `CoreGraphicsImageProcessor.processImage()` returns the resized temp file path, and before Ghost upload:

```swift
if let signingConfig = config.signing, !noSign {
    let signer = GPGImageSigner(config: signingConfig)
    try await signer.sign(imageAt: resizedPath)
}
```

### Config Model Addition

```swift
struct SigningConfig: Codable {
    let keyFingerprint: String
    var xmpNamespace: String = "http://quigs.photo/xmp/1.0/"
    var xmpPrefix: String = "quigsphoto"
}
```

Added as `signing: SigningConfig?` on `AppConfig`.

## Dependencies

### System

- `gnupg` — required at runtime when signing is enabled. Added as a Homebrew formula dependency (`depends_on "gnupg"`).
- At runtime, if signing is enabled but `gpg` is not found on `$PATH`, fail with: `"GPG not found. Install with: brew install gnupg"`

### Swift Packages

No new Swift package dependencies. Uses:
- `Foundation.Process` for shelling out to `gpg`
- `CoreGraphics` / `ImageIO` for XMP writing via `CGImageMetadata` APIs (`CGImageMetadataCreateMutable`, `CGImageMetadataSetValueMatchingImageProperty`, etc. — the lower-level metadata API, not the `kCGImageProperty*` dictionary path)
- `CommonCrypto` / `CryptoKit` for SHA-256 (already available on macOS)

## Dry Run

`--dry-run` logs what would be signed but does not invoke GPG or modify the image. Example: `[dry-run] Would sign image: IMG_1234.jpg with key ABCD1234`

## Logging

- Info level: `Signed image: <filename> with key <short-fingerprint>`
- Debug level: `Content hash: <full-sha256-hex>`

## Future Work (Out of Scope)

- Signing Ghost responsive image variants (Options 1 or 2 from brainstorming)
- Steganographic signing (embedding signatures in pixel data to survive re-encoding)
- Publishing the public key to a keyserver or embedding it in the image
- Web-based verification (JS tool on quigs.photo)
