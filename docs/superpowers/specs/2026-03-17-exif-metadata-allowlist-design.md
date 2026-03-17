# EXIF Metadata Allowlist Design

## Problem

The image processor currently uses an opt-out approach: it copies all EXIF, TIFF, and IPTC metadata dictionaries from the source image, then removes specific keys (MakerNote, GPS). This means any new or unknown metadata tag leaks into uploaded images by default, creating a privacy risk for the photo author.

## Solution

Flip to an opt-in model. The processor starts with empty output metadata dictionaries and only copies tags that appear in a configurable allowlist. Nothing leaks unless explicitly permitted.

## Allowlist Format

Each entry uses a `Dictionary.Key` format string:

- `TIFF.Make` — key `Make` from the TIFF dictionary
- `EXIF.DateTimeOriginal` — key `DateTimeOriginal` from the EXIF dictionary
- `IPTC.DigitalSourceType` — key `DigitalSourceType` from the IPTC dictionary

Supported prefixes: `TIFF.`, `EXIF.`, `IPTC.`

## Default Allowlist

The following tags are included by default, chosen to preserve editorial information while stripping everything else:

### Camera body
- `TIFF.Make`
- `TIFF.Model`

### Lens
- `EXIF.LensModel`

### Exposure settings
- `EXIF.FNumber`
- `EXIF.ExposureTime`
- `EXIF.ISOSpeedRatings`
- `EXIF.FocalLength`

### Date taken
- `EXIF.DateTimeOriginal`
- `IPTC.DateCreated`
- `IPTC.TimeCreated`

### Copyright / Author
- `TIFF.Artist`
- `TIFF.Copyright`
- `IPTC.CopyrightNotice`
- `IPTC.Byline`

### Digital source
- `IPTC.DigitalSourceType`

## What Is Excluded

Everything not in the allowlist, including but not limited to:

- GPS / location data
- MakerNote (camera-specific binary blob, may contain serial numbers)
- Software / processing history
- Camera serial numbers
- Thumbnail images (may contain unstripped metadata)
- UserComment
- SubSecTime variants
- Scene/subject metadata

## Config Changes

### `ProcessingConfig`

Add `metadataAllowlist: [String]` field:

```swift
struct ProcessingConfig: Codable, Equatable {
    var maxLongEdge: Int
    var jpegQuality: Int
    var metadataAllowlist: [String]
}
```

### Backward compatibility

Use `decodeIfPresent` with fallback to the default allowlist, matching the existing pattern used by `tagBlocklist`, `requiredTags`, and `cameraModelTags`.

### Setup

The `setup` command seeds `metadataAllowlist` with the default list automatically. No interactive prompt — this is an advanced setting users can edit in `config.json` directly.

## Processor Changes

### `ImageProcessor` protocol

Add `metadataAllowlist: [String]` parameter to the `process()` method.

### `CoreGraphicsImageProcessor`

Replace the current opt-out logic:

```swift
// OLD: copy everything, remove specific keys
var outputProps: [String: Any] = [:]
if var exif = originalProps[...] { exif.removeValue(...); outputProps[...] = exif }
if let tiff = originalProps[...] { outputProps[...] = tiff }
if let iptc = originalProps[...] { outputProps[...] = iptc }
```

With opt-in logic:

1. Parse each allowlist entry by prefix to determine source dictionary and key
2. Look up the key in the corresponding source dictionary
3. If found, add it to the corresponding output dictionary
4. Only include non-empty output dictionaries in the final properties

### Caller changes

`ProcessCommand` passes `config.processing.metadataAllowlist` to the processor.

## Example config.json

```json
{
  "processing": {
    "maxLongEdge": 2000,
    "jpegQuality": 80,
    "metadataAllowlist": [
      "TIFF.Make",
      "TIFF.Model",
      "TIFF.Artist",
      "TIFF.Copyright",
      "EXIF.LensModel",
      "EXIF.FNumber",
      "EXIF.ExposureTime",
      "EXIF.ISOSpeedRatings",
      "EXIF.FocalLength",
      "EXIF.DateTimeOriginal",
      "IPTC.DigitalSourceType",
      "IPTC.CopyrightNotice",
      "IPTC.Byline",
      "IPTC.DateCreated",
      "IPTC.TimeCreated"
    ]
  }
}
```
