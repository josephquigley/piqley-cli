# Robust Image Watermarking — Design Spec

## Overview

Add a robust watermarking layer to `piqley` that embeds an authenticated identifier into the pixel data of each image. This complements the existing XMP-based GPG signing spec by providing a fallback that survives metadata stripping, format conversion (JPEG → WebP/AVIF/PNG), re-encoding, resize, and light edits.

**Goals:**
- **Survive metadata stripping:** Social media and CDNs strip XMP/EXIF — the watermark persists in pixel data
- **Survive format conversion + resize:** Ghost serves WebP/AVIF variants at multiple sizes via Sharp — the watermark survives the full chain (JPEG → WebP → resize to 400px)
- **Survive light edits:** Color adjustments and quality changes don't destroy the watermark
- **Authenticated identification:** The embedded payload proves authorship via a keyed HMAC, not just identity

**Non-goals:**
- Surviving heavy crops (>30%), aggressive filters, or screenshots (best-effort, not guaranteed)
- Replacing the GPG signature — this is a fallback layer, not a substitute

## Relationship to XMP Signing Spec

This spec extends the cryptographic image signing design. The two systems form a layered verification model:

| Layer | Mechanism | Survives | Proves |
|-------|-----------|----------|--------|
| 1 (strongest) | XMP GPG signature | Nothing stripped or re-encoded | Full cryptographic authorship + integrity |
| 2 (robust) | Pixel watermark + reference DB | Metadata stripping, format conversion, resize, light edits | Authenticated authorship via HMAC |

Verification tries layer 1 first. If no XMP is found, falls back to layer 2.

## Approach: PixelSeal via LibTorch Binary

PixelSeal (Meta, December 2025, MIT license) is a neural image watermarking model from the VideoSeal project. It embeds a 256-bit payload into images at any resolution in a single pass — no tiling required. The watermark survives JPEG/WebP/AVIF conversion, resize, and quality reduction.

### Why PixelSeal

- **256-bit payload** — room for image ID + full 128-bit HMAC + strong error correction
- **Any resolution** — processes the full image in one pass, no tiling needed
- **Format-agnostic robustness** — tested: JPEG q80 → WebP q80 → resize to 400px = 99.6% bit accuracy (1 error out of 256)
- **MIT license** — no commercial use restrictions
- **TorchScript model available** — pre-built `.jit` file, no training or conversion required

### Measured Robustness

Tested on 2000x1333 images (typical 3:2 photo at max processing size):

| Scenario | Bit accuracy | Errors (out of 256) |
|----------|-------------|---------------------|
| Original (no conversion) | 100.0% | 0 |
| JPEG q80 → WebP q80 (full size) | 99.6% | 1 |
| JPEG q80 → WebP q80 → resize to 1200px | 99.6% | 1 |
| JPEG q80 → WebP q80 → resize to 400px | 99.6% | 1 |
| JPEG q80 → WebP q60 → resize to 800px | 99.6% | 1 |
| JPEG q40 → resize 1200px → JPEG q60 | 99.2% | 2 |
| JPEG q20 | 97.7% | 6 |

With 80-bit BCH error correction (corrects up to 15 errors), all scenarios above are well within correction range.

### Architecture: Separate LibTorch Binary

PixelSeal's TorchScript model cannot be converted to CoreML due to dynamic control flow in the model graph (runtime branching, dynamic tensor creation in the JND attenuation module). Instead, the model runs via a separate C++ binary built with LibTorch:

**`piqley-watermark`** — a standalone CLI tool that:
- Loads the PixelSeal TorchScript model (218MB `.jit` file)
- Accepts `embed` and `detect` subcommands
- Reads/writes images via LibTorch's image I/O
- Communicates with the main Swift tool via subprocess invocation (same pattern as GPG)

This mirrors how `piqley` already shells out to `gpg` for cryptographic signing.

```
piqley-watermark embed --image <input.jpg> --message <256-bit-hex> --output <output.jpg>
piqley-watermark detect --image <input.jpg>
```

**Embed** reads an image, embeds the 256-bit message, writes the watermarked image.
**Detect** reads an image, extracts 256 raw bit confidences (floats), outputs them as JSON for the Swift tool to interpret (BCH decode, HMAC validation, etc.).

## Payload Structure (256 bits)

| Field | Bits | Purpose |
|-------|------|---------|
| Version | 2 | Payload format version (currently `00`) |
| Image ID | 46 | Random unique identifier generated at signing time |
| HMAC | 128 | HMAC-SHA256 of the image ID, truncated to 128 bits |
| BCH ECC | 80 | Error correction over the 176-bit payload, corrects up to ~15 bit errors |

### Version (2 bits)

Payload format version. Current version: `00`. Provides 4 possible format revisions.

### Image ID (46 bits)

A random 46-bit value generated at watermark time. 70 trillion possible values — no practical collision risk. Maps to a reference record in both the local database and Ghost post metadata.

### HMAC (128 bits)

HMAC-SHA256 of the 46-bit image ID, truncated to 128 bits. Keyed with a dedicated watermark secret stored in the macOS Keychain.

**Key derivation:**
1. On first use (during `setup` or first watermark embed), generate a random 256-bit secret
2. Store it in the macOS Keychain via `KeychainSecretStore` (the project already has Keychain integration)
3. The Keychain entry is keyed by the GPG fingerprint, tying the HMAC key to the signing identity
4. HMAC-SHA256(image_id, keychain_secret) → take first 128 bits

At 128 bits, brute-force forgery is computationally infeasible (2^128 attempts). This eliminates the security concern from the 32-bit design.

### BCH Error Correction (80 bits)

BCH code over the 176-bit data payload (version + ID + HMAC), correcting up to ~15 bit errors. With PixelSeal's measured worst-case of 6 errors (JPEG q=20), we have over 2x safety margin even in extreme scenarios.

## Unified Processing Pipeline

The pipeline consolidates image processing to a single lossy JPEG encode.

### Pipeline steps

1. **Decode** original JPEG to `CGImage` (pixel buffer in memory)
2. **Resize** via `CGContext` — produces a resized `CGImage` (still in memory, no encode)
3. **Write temp PNG** — write the resized `CGImage` to a temporary lossless PNG for the watermark binary
4. **Watermark embed** — shell out to `piqley-watermark embed`, which reads the temp PNG, embeds the payload, and writes a watermarked PNG
5. **Apply metadata allowlist** — filter EXIF/TIFF/IPTC per the allowlist config
6. **Single JPEG encode** — read the watermarked PNG back as `CGImage`, write it + filtered metadata to disk as JPEG (the only lossy encode)
7. **GPG sign** — `SignableContentExtractor` computes content hash from the JPEG on disk, GPG signs it
8. **XMP write** — use `CGImageDestinationCopyImageSource` to embed GPG signature fields without re-encoding the JPEG
9. **Record watermark reference** — write to `watermarks.jsonl`
10. **Upload** to Ghost as normal
11. **Cleanup** — remove temporary PNG files

Steps 3-4 use PNG (lossless) as the interchange format between Swift and the watermark binary. This ensures the watermark binary receives exact pixel data and its output is not double-compressed. The only lossy JPEG encode happens at step 6.

**Note:** This supersedes the XMP signing plan's `writeXMPSignature` implementation, which uses `CGImageDestinationAddImageAndMetadata` — that approach re-encodes the JPEG. Step 8 uses `CGImageDestinationCopyImageSource` instead, which copies the compressed bitstream without re-encoding.

### Impact on existing code

`CoreGraphicsImageProcessor.process()` currently returns a file path (encodes to JPEG internally). This must change to return a `CGImage` so the watermark step can operate on pixels before encoding. The JPEG encoding moves to a new `ImageFinalizer` that handles both metadata and encoding in one pass.

## Reference Database

### Local — `watermarks.jsonl`

Follows the existing JSONL pattern used by `UploadLog` and `EmailLog`. Each line records one watermarked image:

```json
{"imageId": "a1b2c3d4e5f6", "originalFilename": "IMG_1234.jpg", "contentHash": "sha256hex...", "ghostPostId": "abc123", "ghostPostUrl": "https://quigs.photo/p/...", "modelVersion": "pixelseal-1.0", "timestamp": "2026-03-17T14:30:00Z"}
```

The `modelVersion` field tracks which watermarking model was used to embed this image. When verifying, the Swift tool passes this as a hint to the watermark binary via `--model-version`, so it knows which model to load. This allows the binary to ship multiple model versions and try them in sequence (newest first, fall back to older) when the hint is unavailable.

File location: alongside existing logs in the config directory.

### Ghost backup

The image ID is stored in the Ghost post via a Lexical HTML card appended to the post body. `LexicalBuilder` constructs Lexical JSON nodes (not raw HTML), so the watermark ID is added as an HTML card node containing a hidden `<span>`:

```json
{
  "type": "html",
  "html": "<span data-piqley-id=\"a1b2c3d4e5f6\" style=\"display:none\"></span>"
}
```

This approach works within Ghost's Lexical editor format (the feature image is a separate post field, not an element in the Lexical body, so data attributes on `<img>` would not work). The hidden span is invisible to readers but queryable via the Ghost Content API.

### Lookup flow

1. Extract watermark → get image ID
2. Check local `watermarks.jsonl` first (fast, offline)
3. If not found locally, query Ghost API by searching for `data-piqley-id` in post HTML content
4. Return full record: original filename, content hash, Ghost URL, timestamp

## Verification

The `verify` subcommand (from the XMP signing spec) gains a watermark extraction fallback:

```
piqley verify <image-path> [--key-fingerprint <fp>]
```

### Verification flow

1. **Try XMP first:** Read `piqley:signature` fields. If present, verify GPG signature and content hash (existing spec). Report results and exit.
2. **Fall back to watermark:** If no XMP signature found, attempt watermark extraction:
   a. Shell out to `piqley-watermark detect --image <path>` — decodes any format (JPEG, PNG, WebP, AVIF)
   b. Parse the 256 raw bit confidences from JSON output
   c. Threshold to binary (>0 = 1, ≤0 = 0)
   d. Apply BCH error correction
   e. Validate HMAC with Keychain-stored watermark secret
   f. If HMAC valid, look up image ID in reference database
3. **Report results:**
   - **Watermark found, HMAC valid:** "Watermark verified. Image ID: a1b2c3d4e5f6. Originally: IMG_1234.jpg, uploaded 2026-03-17."
   - **Watermark found, HMAC invalid:** "Watermark detected but authentication failed. This may be a forgery or the image is too degraded."
   - **No watermark found:** "No signature or watermark found in this image."

### Format-agnostic verification

The watermark binary handles image decoding internally via LibTorch's image I/O, which supports JPEG, PNG, WebP, and other common formats. The Swift tool does not need to decode the image for watermark extraction — it passes the file path to the binary.

## Configuration

### Additions to `SigningConfig`

The existing `SigningConfig` (added by the XMP signing spec) gains one new field:

```swift
struct SigningConfig: Codable, Equatable {
    var keyFingerprint: String
    var xmpNamespace: String?   // existing, derived from ghost.url if nil
    var xmpPrefix: String       // existing, defaults to "piqley"
    var watermark: Bool         // NEW — defaults to true
}
```

The `watermark` field follows the existing `decodeIfPresent` pattern used by `xmpNamespace` and `xmpPrefix` in `SigningConfig.init(from:)`.

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

### New project: `piqley-watermark` (C++ / LibTorch)

A separate C++ binary that owns all neural network inference. Keeps the main Swift project free of ML framework dependencies.

```
piqley-watermark/
├── CMakeLists.txt              (build config, links LibTorch)
├── src/
│   ├── main.cpp                (CLI entry point: embed/detect subcommands)
│   ├── embed.cpp               (load model, embed message, write output)
│   ├── detect.cpp              (load model, extract bits, output JSON)
│   └── image_io.cpp            (image read/write via stb_image / LibTorch)
├── model/
│   └── pixelseal.jit           (218MB TorchScript model)
└── Formula/
    └── piqley-watermark.rb (Homebrew formula)
```

**CLI interface:**

```bash
# Embed: reads image, embeds 256-bit message, writes watermarked image
piqley-watermark embed \
  --image input.jpg \
  --message "a1b2c3...64-hex-chars" \
  --output watermarked.png

# Detect: reads image, outputs raw bit confidences as JSON
piqley-watermark detect --image input.jpg [--model-version pixelseal-1.0]
# stdout: {"bits": [3.14, -2.71, 8.12, ...], "confidence": 0.95, "modelVersion": "pixelseal-1.0"}
```

**Detect output format:** JSON with three fields:
- `bits`: array of 256 floats — raw model output before thresholding. Positive = bit is 1, negative = bit is 0. Magnitude indicates confidence.
- `confidence`: float — first output from the model (watermark presence score). Not currently used but available for future "is this watermarked?" detection.
- `modelVersion`: string — which model produced this result (e.g., `"pixelseal-1.0"`).

**Model versioning:** The binary can ship multiple `.jit` model files. The `--model-version` flag on `detect` specifies which model to use. If omitted, the binary tries all models newest-first and returns the result with the highest confidence. This allows graceful upgrades: new images use the latest model, old images can still be verified.

The Swift tool handles all payload logic (BCH decode, HMAC validation, reference lookup) — the binary is a thin wrapper around the model.

### New files in `piqley` (Swift)

```
Sources/piqley/
├── Watermarking/
│   ├── ImageWatermarker.swift           (protocol)
│   ├── PixelSealWatermarker.swift       (subprocess invocation of piqley-watermark)
│   ├── WatermarkPayload.swift           (encode/decode: ID, HMAC, BCH for 256 bits)
│   └── WatermarkReference.swift         (JSONL read/write for watermarks.jsonl)
```

### Modified files in `piqley`

```
Sources/piqley/
├── ImageProcessing/
│   ├── ImageProcessor.swift             (protocol: add resize method returning CGImage)
│   ├── CoreGraphicsImageProcessor.swift (add resize, refactor process to use it)
│   └── ImageFinalizer.swift             (NEW: single JPEG encode + XMP write without re-encode)
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
    func embed(imagePath: String, payload: WatermarkPayload) throws -> String  // returns watermarked image path
    func extract(imagePath: String) throws -> [Float]  // returns 256 raw confidences
}

struct WatermarkPayload {
    static let currentVersion: UInt8 = 0
    let version: UInt8        // 2-bit (0-3)
    let imageId: UInt64       // 46-bit
    let hmac: Data            // 128-bit (16 bytes)

    func encode() -> [Bool]   // → 256 bits (2 version + 46 ID + 128 HMAC + 80 BCH)
    static func decode(from bits: [Bool], hmacKey: Data) -> WatermarkPayload?

    init(imageId: UInt64, hmacKey: Data) {
        precondition(imageId < (1 << 46), "Image ID must fit in 46 bits")
        self.version = Self.currentVersion
        self.imageId = imageId
        self.hmac = Self.computeHMAC(imageId: imageId, key: hmacKey)
    }
}
```

### Integration in ProcessCommand

```swift
// Unified pipeline
let (resizedImage, filteredMetadata) = try processor.resize(
    inputPath: image.path,
    maxLongEdge: config.processing.maxLongEdge,
    metadataAllowlist: config.processing.metadataAllowlist
)

var watermarkId: String? = nil
var imageForEncoding = resizedImage

if let signingConfig = config.resolvedSigningConfig, signingConfig.watermark, !noWatermark {
    if !dryRun {
        // Write resized image to temp PNG (lossless interchange)
        let tempPng = tempDir + "/\(image.filename).resize.png"
        try ImageFinalizer.writePNG(resizedImage, to: tempPng)

        // Embed watermark via subprocess
        let imageId = WatermarkPayload.generateImageId()
        let hmacKey = try secretStore.getOrCreateWatermarkKey(for: signingConfig.keyFingerprint)
        let payload = WatermarkPayload(imageId: imageId, hmacKey: hmacKey)
        let watermarkedPng = try watermarker.embed(imagePath: tempPng, payload: payload)

        // Read back watermarked pixels
        imageForEncoding = try ImageFinalizer.readCGImage(from: watermarkedPng)
        watermarkId = String(imageId, radix: 16)
        logger.info("[\(image.filename)] Watermark embedded (ID: \(watermarkId!))")
    } else {
        let fakeId = String(WatermarkPayload.generateImageId(), radix: 16)
        print("[\(image.filename)] Would embed watermark (image ID: \(fakeId))")
    }
}

// Single JPEG encode with filtered metadata
try ImageFinalizer.writeJPEG(imageForEncoding, metadata: filteredMetadata,
                              quality: config.processing.jpegQuality, to: resizedPath)

// GPG sign (XMP write via CGImageDestinationCopyImageSource — no re-encode)
if let signingConfig = config.resolvedSigningConfig, !noSign {
    let signer = GPGImageSigner(config: signingConfig)
    try await signer.sign(imageAt: resizedPath)
}
```

## Dependencies

### `piqley-watermark` binary
- **LibTorch** (~200MB) — C++ PyTorch runtime for TorchScript model execution
- **stb_image / stb_image_write** — lightweight C image I/O (header-only, vendored)
- **PixelSeal model** — `pixelseal.jit` (218MB TorchScript file)

### `piqley` (Swift)
- No new Swift package dependencies
- No new system framework dependencies
- Shells out to `piqley-watermark` (same pattern as `gpg`)

### Homebrew distribution

Two formulas:
- `piqley-watermark` — the C++ binary. `depends_on "libtorch"`. The model file is downloaded as a `resource` block in the formula.
- `piqley` — gains `depends_on "piqley-watermark"` (optional, only when watermarking is enabled)

At runtime, if watermarking is enabled but `piqley-watermark` is not found on `$PATH`, fail with: `"piqley-watermark not found. Install with: brew install piqley-watermark"`

## Perceptual Quality

PixelSeal uses JND (Just Noticeable Difference) attenuation — it automatically reduces watermark strength in perceptually sensitive regions. This is built into the model, not a post-processing step.

**Acceptance criteria (validate during implementation):**
1. SSIM between original and watermarked image ≥ 0.98
2. Visual inspection of 10+ test images at full resolution, focusing on sky/gradient regions
3. No visible artifacts when viewing at intended display size (web, ~2000px)

## Error Handling

Watermark failures follow the same philosophy as GPG signing: **fatal when configured.**

If watermarking is enabled and embedding fails (binary not found, model loading error, subprocess crash), the tool exits with code 1. Use `--no-watermark` to explicitly opt out.

Extraction failures during `verify` are non-fatal — the command reports "no watermark found" and exits with code 1.

## Dry Run

`--dry-run` logs what would be watermarked but does not invoke the watermark binary:

```
[IMG_1234.jpg] Would embed watermark (image ID: a1b2c3d4e5f6)
```

## Logging

- Info: `Watermark embedded: <filename> (ID: <hex-id>)`
- Debug: `Watermark binary: <path> embed --image <input> --message <hex> --output <output>`

## Future Work (Out of Scope)

- Web-based verification (JS decoder on quigs.photo)
- Batch verification of an entire Ghost site
- Watermark strength configuration
- CoreML conversion if PixelSeal's model graph is simplified in a future release
