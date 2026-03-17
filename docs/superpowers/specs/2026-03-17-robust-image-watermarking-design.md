# Robust Image Watermarking — Design Spec

## Overview

Add a robust watermarking layer to `quigsphoto-uploader` that embeds an authenticated identifier into the pixel data of each image. This complements the existing XMP-based GPG signing spec by providing a fallback that survives metadata stripping, format conversion (JPEG → WebP/AVIF/PNG), re-encoding, and light edits.

**Goals:**
- **Survive metadata stripping:** Social media and CDNs strip XMP/EXIF — the watermark persists in pixel data
- **Survive format conversion:** Ghost serves WebP/AVIF variants via Sharp — the watermark survives re-encoding across formats
- **Survive light edits:** Cropping, color adjustments, and quality changes don't destroy the watermark
- **Authenticated identification:** The embedded payload proves authorship via a keyed HMAC, not just identity

**Non-goals:**
- Surviving heavy crops (>30%), aggressive filters, or screenshots (best-effort, not guaranteed)
- Replacing the GPG signature — this is a fallback layer, not a substitute

## Relationship to XMP Signing Spec

This spec extends the cryptographic image signing design. The two systems form a layered verification model:

| Layer | Mechanism | Survives | Proves |
|-------|-----------|----------|--------|
| 1 (strongest) | XMP GPG signature | Nothing stripped or re-encoded | Full cryptographic authorship + integrity |
| 2 (robust) | Pixel watermark + reference DB | Metadata stripping, format conversion, light edits | Authenticated authorship via HMAC |

Verification tries layer 1 first. If no XMP is found, falls back to layer 2.

## Approach: StegaStamp via CoreML

StegaStamp (Berkeley, 2019, MIT license) is a neural watermarking model that embeds a 100-bit payload into images. It was designed to survive printing and re-photographing — digital re-encoding is a gentler distortion. The encoder and decoder are converted to CoreML models and bundled with the tool.

### Why StegaStamp

- **100-bit payload** — enough for image ID + HMAC + error correction
- **Robustness** — designed for print-and-photograph survival; digital format conversion is well within tolerance
- **MIT license** — no commercial use restrictions
- **CoreML convertible** — PyTorch → CoreML, runs on Apple Neural Engine / GPU with no Python runtime dependency

### Prerequisite: CoreML Conversion Validation

Before implementation begins, the StegaStamp PyTorch encoder and decoder must be converted to CoreML and validated. StegaStamp uses learned perturbation networks and differentiable JPEG simulation layers that may not all have direct CoreML equivalents.

**Validation steps (one-time, before implementation):**
1. Clone the StegaStamp repository and load the published weights
2. Convert encoder and decoder to CoreML via `coremltools`
3. Run both models on a test image and compare outputs to the PyTorch originals
4. Verify bit-accurate payload recovery through the CoreML encode → decode round-trip

If conversion fails, fallback options in order of preference:
1. Simplify the model graph (remove training-only layers like differentiable JPEG simulation) before conversion
2. Use ONNX as an intermediate format (`PyTorch → ONNX → CoreML`)
3. Fall back to Approach 2 (Python sidecar) from this design's brainstorming phase

## Payload Structure (100 bits)

| Field | Bits | Purpose |
|-------|------|---------|
| Version | 2 | Payload format version (currently `00`) |
| Image ID | 46 | Random unique identifier generated at signing time |
| HMAC | 32 | HMAC-SHA256 of the image ID, truncated to 32 bits |
| BCH ECC | 20 | Error correction over the 80-bit payload (version + ID + HMAC), corrects up to 4 bit errors |

### Version (2 bits)

Payload format version. Allows future changes to field sizes or ECC scheme without ambiguity. Current version: `00`. Provides 4 possible format revisions.

### Image ID (46 bits)

A random 46-bit value generated at watermark time. 70 trillion possible values — no practical collision risk even with random generation. Maps to a reference record in both the local database and Ghost post metadata.

### HMAC (32 bits)

HMAC-SHA256 of the 46-bit image ID, keyed with a dedicated watermark secret stored in the macOS Keychain.

**Key derivation:**
1. On first use (during `setup` or first watermark embed), generate a random 256-bit secret
2. Store it in the macOS Keychain via `KeychainSecretStore` (the project already has Keychain integration)
3. The Keychain entry is keyed by the GPG fingerprint, tying the HMAC key to the signing identity
4. HMAC-SHA256(image_id, keychain_secret) → truncate to 32 bits

This approach avoids deriving the HMAC key from GPG export output, which varies across GPG versions and key operations. The Keychain secret is stable, backed up by macOS Keychain sync, and tied to the signing identity by its storage key.

**Security note:** At 32 bits, brute-force forgery requires ~4 billion attempts — computationally feasible but non-trivial. This is acceptable for a fallback attribution layer. For high-stakes disputes, the XMP GPG signature (layer 1) provides full cryptographic proof.

### BCH Error Correction (20 bits)

BCH code over the 80-bit payload (version + ID + HMAC) providing correction of up to 4 bit errors. At typical StegaStamp per-bit accuracy of 95-99% on digitally re-encoded images, this pushes successful extraction above 90% even in degraded scenarios.

**Estimated** extraction success rates (rough estimates based on published per-bit accuracy, not measured values — actual performance should be validated during implementation):

| Scenario | Without ECC (est.) | With 20-bit BCH (est.) |
|----------|-------------|-----------------|
| Clean JPEG re-encode | ~99% | ~99.9% |
| JPEG → WebP moderate quality | ~92% | ~98% |
| JPEG → AVIF + mild crop | ~85% | ~93% |
| Heavy crop + format change + low quality | ~60% | ~78% |

## Unified Processing Pipeline

The existing cryptographic signing plan introduces a pipeline with multiple JPEG decode/encode cycles. This spec consolidates the pipeline to a single lossy encode, improving both image quality and watermark robustness.

### Current plan (3 lossy encodes)

```
Decode → Resize → Encode#1 → Decode → Watermark → Encode#2 → Decode → XMP Write → Encode#3
```

### Unified pipeline (1 lossy encode)

```
Decode → Resize (in memory) → Watermark (in memory) → Single JPEG Encode → XMP Write (no re-encode)
```

### Pipeline steps

1. **Decode** original JPEG to `CGImage` (pixel buffer in memory)
2. **Resize** via `CGContext` — produces a resized `CGImage` (still in memory, no encode)
3. **Watermark embed** — StegaStamp encoder runs on tiles of the resized `CGImage`, produces a watermarked `CGImage`
4. **Apply metadata allowlist** — filter EXIF/TIFF/IPTC per the allowlist config
5. **Single JPEG encode** — write the watermarked `CGImage` + filtered metadata to disk as JPEG (the only lossy encode)
6. **GPG sign** — `SignableContentExtractor` computes content hash from the JPEG on disk, GPG signs it
7. **XMP write** — read the JPEG back as a `CGImageSource`, then use `CGImageDestinationCopyImageSource` to copy the compressed bitstream to a new destination with the XMP signature fields added. This copies the JPEG data byte-for-byte — no decode or re-encode occurs.
8. **Record watermark reference** — write to `watermarks.jsonl`
9. **Upload** to Ghost as normal

**Important:** Step 7 requires reading the JPEG from step 5 back as a `CGImageSource`. `CGImageDestinationCopyImageSource` operates on source data (compressed bitstream), not on a `CGImage` in memory. The sequence is: create `CGImageSource` from the JPEG file → create `CGImageDestination` for the output → call `CGImageDestinationCopyImageSource` with metadata options that include the XMP signature fields. The compressed image data passes through unchanged.

**Note:** This supersedes the XMP signing plan's `writeXMPSignature` implementation, which uses `CGImageDestinationAddImageAndMetadata` with a decoded `CGImage` — that approach re-encodes the JPEG. The implementation plan (Task 3, Step 5) should be updated to use `CGImageDestinationCopyImageSource` instead.

### Impact on existing code

`CoreGraphicsImageProcessor.process()` currently returns a file path (encodes to JPEG internally). This must change to return a `CGImage` so the watermark step can operate on pixels before encoding. The JPEG encoding moves to a new finalization step that handles both metadata and encoding in one pass.

## Tiling Strategy

StegaStamp's published model operates on 400x400 pixel inputs. Images processed by `quigsphoto-uploader` are up to 2000px on the long edge (e.g., 2000x1333 for 3:2 aspect ratio). Tiling bridges the gap.

### Embedding

1. Compute a tile grid over the image with 40px overlap per edge (effective stride: 360px)
2. For a 2000x1333 image: ~5 columns x ~4 rows = ~20 tiles
3. For each tile:
   - Extract the 400x400 region from the source `CGImage`
   - Run the StegaStamp encoder CoreML model with the 100-bit payload
   - Receive the watermarked 400x400 region
4. Reassemble: in overlap zones, feather-blend using a linear ramp (0→1 over 40px) to eliminate visible seams
5. The result is a single watermarked `CGImage`

### Extraction

Extraction should be performed on the highest-resolution version of the image available. For Ghost images, this means the original upload (strip `/size/wXXX/` from variant URLs). Resized variants will have different tile grids than the original, reducing extraction reliability.

1. Tile the input image using the same grid parameters (computed from image dimensions — the grid is deterministic for a given width/height, so it does not need to be stored)
2. Run the StegaStamp decoder on each tile → 100-bit candidate per tile
3. **Majority vote per bit:** For each of the 100 bit positions, take the majority value across all tiles
4. Apply BCH error correction to the voted result
5. Extract the 2-bit version, 46-bit image ID, and 32-bit HMAC
6. Validate HMAC

### Why majority vote works

With ~20 tiles, even if 30% of the image is cropped (losing ~6 tiles), 14 tiles remain. Each surviving tile votes independently per bit. At 95% per-bit accuracy per tile, majority vote across 14 tiles pushes effective per-bit accuracy above 99.9%.

### Performance

- CoreML on Apple Silicon: ~10-20ms per tile forward pass
- 20 tiles: ~200-400ms per image for embedding or extraction
- Acceptable for a CLI tool processing a handful of images per run

## Reference Database

### Local — `watermarks.jsonl`

Follows the existing JSONL pattern used by `UploadLog` and `EmailLog`. Each line records one watermarked image:

```json
{"imageId": "a1b2c3d4e5f6", "originalFilename": "IMG_1234.jpg", "contentHash": "sha256hex...", "ghostPostId": "abc123", "ghostPostUrl": "https://quigs.photo/p/...", "timestamp": "2026-03-17T14:30:00Z"}
```

File location: alongside existing logs in the config directory.

### Ghost backup

The image ID is stored in the Ghost post via a Lexical HTML card appended to the post body. `LexicalBuilder` constructs Lexical JSON nodes (not raw HTML), so the watermark ID is added as an HTML card node containing a hidden `<span>`:

```json
{
  "type": "html",
  "html": "<span data-quigsphoto-id=\"a1b2c3d4e5f6\" style=\"display:none\"></span>"
}
```

This approach works within Ghost's Lexical editor format (the feature image is a separate post field, not an element in the Lexical body, so data attributes on `<img>` would not work). The hidden span is invisible to readers but queryable via the Ghost Content API.

### Lookup flow

1. Extract watermark → get image ID
2. Check local `watermarks.jsonl` first (fast, offline)
3. If not found locally, query Ghost API by searching for `data-quigsphoto-id` in post HTML content
4. Return full record: original filename, content hash, Ghost URL, timestamp

## Verification

The `verify` subcommand (from the XMP signing spec) gains a watermark extraction fallback:

```
quigsphoto verify <image-path> [--key-fingerprint <fp>]
```

### Verification flow

1. **Try XMP first:** Read `quigsphoto:signature` fields. If present, verify GPG signature and content hash (existing spec). Report results and exit.
2. **Fall back to watermark:** If no XMP signature found, attempt watermark extraction:
   a. Decode image (any format: JPEG, PNG, WebP, AVIF — all supported by `CGImageSource`)
   b. Tile and run StegaStamp decoder
   c. Majority vote + BCH error correction
   d. Validate HMAC with Keychain-stored watermark secret
   e. If HMAC valid, look up image ID in reference database
3. **Report results:**
   - **Watermark found, HMAC valid:** "Watermark verified. Image ID: a1b2c3d4e5f6. Originally: IMG_1234.jpg, uploaded 2026-03-17."
   - **Watermark found, HMAC invalid:** "Watermark detected but authentication failed. This may be a forgery or the image is too degraded."
   - **No watermark found:** "No signature or watermark found in this image."

### Format-agnostic verification

The watermark lives in pixel data. At extraction time, the image is decoded to a `CGImage` regardless of source format. `ImageIO` on macOS supports JPEG, PNG, WebP, AVIF, HEIC, TIFF, and others natively. The decoder doesn't care what format the pixels came from.

## Configuration

### Additions to `SigningConfig`

The existing `SigningConfig` (added by the XMP signing spec) gains one new field:

```swift
struct SigningConfig: Codable, Equatable {
    var keyFingerprint: String
    var xmpNamespace: String?   // existing, derived from ghost.url if nil
    var xmpPrefix: String       // existing, defaults to "quigsphoto"
    var watermark: Bool         // NEW — defaults to true
}
```

The `watermark` field follows the existing `decodeIfPresent` pattern used by `xmpNamespace` and `xmpPrefix` in `SigningConfig.init(from:)`. The `xmpNamespace` is `nil` by default and derived at runtime from `ghost.url` via `resolvedSigningConfig`.

When `signing` is present in config and `watermark` is `true` (default), watermarking is enabled.

### CLI flags

- `--no-sign` — skip GPG signing (existing, from XMP spec)
- `--no-watermark` — skip watermark embedding
- These are independent: you can watermark without signing, or sign without watermarking

### Example config

```json
{
  "signing": {
    "keyFingerprint": "ABCD1234...",
    "watermark": true
  }
}
```

## Architecture

### New files

```
Sources/quigsphoto-uploader/
├── Watermarking/
│   ├── ImageWatermarker.swift           (protocol)
│   ├── StegaStampWatermarker.swift      (CoreML tiling, embed, extract)
│   ├── WatermarkPayload.swift           (encode/decode: ID, HMAC, BCH)
│   ├── TileGrid.swift                   (tile coordinates, overlap, blending)
│   └── WatermarkReference.swift         (JSONL read/write for watermarks.jsonl)
Resources/
├── StegaStampEncoder.mlmodelc
└── StegaStampDecoder.mlmodelc
```

### Modified files

```
Sources/quigsphoto-uploader/
├── ImageProcessing/
│   ├── ImageProcessor.swift             (protocol: return CGImage instead of file path)
│   └── CoreGraphicsImageProcessor.swift (return CGImage, defer JPEG encoding)
├── CLI/
│   ├── ProcessCommand.swift             (unified pipeline, --no-watermark flag)
│   └── VerifyCommand.swift              (watermark extraction fallback)
├── Ghost/
│   └── LexicalBuilder.swift             (add hidden HTML card with watermark ID)
├── Config/
│   └── Config.swift                     (watermark field on SigningConfig)
```

### Protocols

```swift
protocol ImageWatermarker {
    func embed(in image: CGImage, payload: WatermarkPayload) throws -> CGImage
    func extract(from image: CGImage) throws -> WatermarkPayload?
}

struct WatermarkPayload {
    static let currentVersion: UInt8 = 0  // 2-bit version field
    let version: UInt8        // 2-bit (0-3)
    let imageId: UInt64       // 46-bit (upper 18 bits zero, validated in init)
    let hmac: UInt32          // 32-bit truncated HMAC

    func encode() -> [Bool]   // → 100 bits (2 version + 46 ID + 32 HMAC + 20 BCH)
    static func decode(from bits: [Bool]) -> WatermarkPayload?  // BCH correct → validate

    init(imageId: UInt64, hmac: UInt32) {
        precondition(imageId < (1 << 46), "Image ID must fit in 46 bits")
        self.version = Self.currentVersion
        self.imageId = imageId
        self.hmac = hmac
    }

    /// Convenience: compute HMAC internally from the key
    init(imageId: UInt64, hmacKey: Data) {
        let hmac = Self.computeHMAC(imageId: imageId, key: hmacKey)
        self.init(imageId: imageId, hmac: hmac)
    }
}
```

### Integration in ProcessCommand

```swift
// Unified pipeline
let resizedImage = try processor.resize(image, maxLongEdge: config.processing.maxLongEdge)

var finalImage = resizedImage
var watermarkId: String? = nil

if let signingConfig = config.signing, signingConfig.watermark, !noWatermark {
    let watermarker = StegaStampWatermarker()
    let imageId = generateImageId()        // random 46-bit
    let hmacKey = try KeychainSecretStore.loadWatermarkKey(for: signingConfig.keyFingerprint)
    let payload = WatermarkPayload(imageId: imageId, hmacKey: hmacKey)
    finalImage = try watermarker.embed(in: resizedImage, payload: payload)
    watermarkId = String(imageId, radix: 16)
}

// Single JPEG encode with filtered metadata
let outputPath = try ImageFinalizer.write(
    finalImage,
    metadata: filteredMetadata,
    quality: config.processing.jpegQuality,
    to: tempPath
)

// GPG sign (XMP write via CGImageDestinationCopyImageSource — no re-encode)
if let signingConfig = config.signing, !noSign {
    let signer = GPGImageSigner(config: signingConfig)
    try await signer.sign(imageAt: outputPath)
}

// Record watermark reference
if let wId = watermarkId {
    try WatermarkReference.append(imageId: wId, filename: image.filename, to: watermarkLogPath)
}
```

## Dependencies

### New system frameworks
- `CoreML.framework` — StegaStamp model inference
- `Accelerate.framework` — efficient pixel blending for tile reassembly (vImage)

### Bundled resources
- `StegaStampEncoder.mlmodelc` (~10-25MB)
- `StegaStampDecoder.mlmodelc` (~10-25MB)

### No new Swift package dependencies

### One-time model conversion (developer tooling, not runtime)
- Python script to convert StegaStamp PyTorch weights → CoreML via `coremltools`
- Run once, commit the `.mlmodelc` files to the repo

### Distribution impact
The CoreML model files add ~20-50MB to the binary distribution. The current CLI is a lightweight Swift binary. This changes the distribution profile for the Homebrew formula — the formula should use the `resource` block to download models separately from the binary, or accept the larger bottle size. Git LFS should be used for the `.mlmodelc` files in the repo to avoid bloating the git history.

## Perceptual Quality

StegaStamp is designed for imperceptibility, but embedding into high-quality photography requires validation. Areas of concern:

- **Tile boundaries:** Feather blending mitigates seams, but smooth gradients (sky, bokeh) may reveal subtle discontinuities
- **Smooth regions:** Neural watermarks are more perceptible in low-texture areas common in photography

**Acceptance criteria (validate during implementation):**
1. SSIM (Structural Similarity Index) between original and watermarked image ≥ 0.98
2. Visual inspection of 10+ test images at full resolution, focusing on sky/gradient regions and tile boundaries
3. No visible artifacts when viewing at intended display size (web, ~2000px)

If artifacts are visible, options include reducing embedding strength (at the cost of robustness) or increasing tile overlap.

## Error Handling

Watermark failures follow the same philosophy as GPG signing: **fatal when configured.**

If watermarking is enabled and embedding fails (model loading error, CoreML failure), the tool exits with code 1. Rationale: if watermarking is configured, silently publishing unwatermarked images defeats the purpose. Use `--no-watermark` to explicitly opt out.

Extraction failures during `verify` are non-fatal — the command reports "no watermark found" and exits with code 1.

## Dry Run

`--dry-run` logs what would be watermarked but does not run the CoreML model or modify the image:

```
[IMG_1234.jpg] Would embed watermark (image ID: a1b2c3d4e5f6)
```

## Logging

- Info: `Watermark embedded: <filename> (ID: <hex-id>)`
- Debug: `Tiling: <cols>x<rows> = <count> tiles for <width>x<height> image`
- Debug: `Watermark extraction: <bit-accuracy>% per-bit accuracy across <tile-count> tiles`

## Future Work (Out of Scope)

- Web-based verification (JS decoder on quigs.photo)
- Batch verification of an entire Ghost site
- Watermark strength configuration (trade-off: visibility vs. robustness)
- Fine-tuning StegaStamp on photography-specific images for better imperceptibility
