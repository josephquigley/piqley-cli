# Write Action Gaps and Metadata Sanitizer Plugin

## Overview

Two related changes: (1) fix missing clone and template resolution support in write actions, and (2) create a rules-only metadata sanitizer plugin that uses those features to strip non-allowed metadata from images before publishing.

## Part 1: Write Action Gap Fix

### Problem

Write actions in `RuleEvaluator.evaluate()` are passed directly to `MetadataBuffer.applyAction()` without template resolution or clone handling. This means:

1. **Template resolution**: Emit actions go through `resolveTemplates()` before application, but write actions do not. An `add` write action with `{{original:EXIF:FNumber}}` would pass the literal string instead of the resolved value.
2. **Clone**: The `applyAction()` static method treats `clone` as a no-op (`break`). For emit actions, clone is handled inline in the evaluate loop (lines 299-318) where it has access to `state` and the metadata buffer. Write actions have no equivalent handling.

### Changes

#### 1. Template resolution for write actions

In `RuleEvaluator.evaluate()`, apply `resolveTemplates()` to each write action before passing it to the buffer. The existing `resolveTemplates` method already handles the `add` case with `{{...}}` syntax and has access to state, buffer, image name, and plugin ID.

Current code (lines 337-342):
```swift
// Write actions second (modify file metadata via buffer)
if let buffer = metadataBuffer, let image = imageName {
    for action in rule.writeActions {
        await buffer.applyAction(action, image: image)
    }
}
```

Updated:
```swift
// Write actions second (modify file metadata via buffer)
if let buffer = metadataBuffer, let image = imageName {
    for action in rule.writeActions {
        let resolvedAction = await resolveTemplates(
            in: action,
            state: state,
            metadataBuffer: metadataBuffer,
            imageName: imageName,
            pluginId: pluginId
        )
        await buffer.applyAction(resolvedAction, image: image)
    }
}
```

#### 2. Clone support for write actions

Handle clone inline in the write action loop, similar to the emit path. When a clone write action is encountered, resolve the source value from `state` (for `original:` and plugin namespaces) or from the buffer (for `read:` namespace), then apply it to the buffer's image metadata.

Add a new method to `MetadataBuffer`:

```swift
/// Merge a resolved value into a specific field for an image's metadata.
func applyClone(field: String, value: JSONValue, image: String) {
    if metadata[image] == nil {
        _ = load(image: image)
    }
    var current = metadata[image] ?? [:]
    RuleEvaluator.mergeClonedValue(value, into: &current, forKey: field)
    metadata[image] = current
    dirty.insert(image)
}
```

And a bulk variant for wildcard clones:

```swift
/// Merge all key-value pairs from a resolved namespace into an image's metadata.
func applyCloneAll(values: [String: JSONValue], image: String) {
    if metadata[image] == nil {
        _ = load(image: image)
    }
    var current = metadata[image] ?? [:]
    for (key, val) in values {
        RuleEvaluator.mergeClonedValue(val, into: &current, forKey: key)
    }
    metadata[image] = current
    dirty.insert(image)
}
```

In the write action loop:
```swift
if let buffer = metadataBuffer, let image = imageName {
    for action in rule.writeActions {
        if case let .clone(field, sourceNamespace, sourceField) = action {
            if sourceNamespace == "read" {
                let fileMetadata = await buffer.load(image: image)
                if field == "*" {
                    await buffer.applyCloneAll(values: fileMetadata, image: image)
                } else if let sourceField, let val = fileMetadata[sourceField] {
                    await buffer.applyClone(field: field, value: val, image: image)
                }
            } else if field == "*" {
                if let namespaceData = state[sourceNamespace] {
                    await buffer.applyCloneAll(values: namespaceData, image: image)
                }
            } else if let sourceField, let val = state[sourceNamespace]?[sourceField] {
                await buffer.applyClone(field: field, value: val, image: image)
            }
            continue
        }
        let resolvedAction = await resolveTemplates(
            in: action,
            state: state,
            metadataBuffer: metadataBuffer,
            imageName: imageName,
            pluginId: pluginId
        )
        await buffer.applyAction(resolvedAction, image: image)
    }
}
```

### Testing

- Template resolution in write `add` actions resolves `{{original:EXIF:FNumber}}` to the actual value
- Clone in write actions copies a field from `original:` namespace into file metadata
- Wildcard clone (`field: "*"`) copies all fields from a namespace into file metadata
- Clone from `read:` namespace works in write context
- Existing emit-side behavior is unchanged

## Part 2: Metadata Sanitizer Plugin

### Identity

- Identifier: `photo.quigs.metadata-sanitizer`
- Name: Metadata Sanitizer
- Type: mutable (rules-only, no binary)
- Stage: post-process (preRules)
- Fork: none (write actions apply directly to main pipeline images)

### Allowlist

17 fields across 4 namespaces:

| Namespace | Fields |
|-----------|--------|
| TIFF | Orientation, Make, Model, Artist, Copyright |
| EXIF | DateTimeOriginal, ExposureTime, FNumber, ISO, FocalLength, ColorSpace, PixelXDimension, PixelYDimension |
| IPTC | Byline, Copyright, CopyrightNotice |
| XMP | Creator, Rights |

All other fields in EXIF, IPTC, XMP, and TIFF are removed. Plugin state namespaces are not touched.

### Rule Structure

The plugin's `stage-post-process.json` contains two rules executed in order:

**Rule 1: Wipe all file metadata**
```json
{
  "write": [
    { "action": "removeField", "field": "*" }
  ]
}
```

No match condition (unconditional). Removes every field from the image's file metadata via the MetadataBuffer.

**Rule 2: Restore allowed fields from original**
```json
{
  "write": [
    { "action": "clone", "field": "TIFF:Orientation", "source": "original:TIFF:Orientation" },
    { "action": "clone", "field": "TIFF:Make", "source": "original:TIFF:Make" },
    { "action": "clone", "field": "TIFF:Model", "source": "original:TIFF:Model" },
    { "action": "clone", "field": "TIFF:Artist", "source": "original:TIFF:Artist" },
    { "action": "clone", "field": "TIFF:Copyright", "source": "original:TIFF:Copyright" },
    { "action": "clone", "field": "EXIF:DateTimeOriginal", "source": "original:EXIF:DateTimeOriginal" },
    { "action": "clone", "field": "EXIF:ExposureTime", "source": "original:EXIF:ExposureTime" },
    { "action": "clone", "field": "EXIF:FNumber", "source": "original:EXIF:FNumber" },
    { "action": "clone", "field": "EXIF:ISO", "source": "original:EXIF:ISO" },
    { "action": "clone", "field": "EXIF:FocalLength", "source": "original:EXIF:FocalLength" },
    { "action": "clone", "field": "EXIF:ColorSpace", "source": "original:EXIF:ColorSpace" },
    { "action": "clone", "field": "EXIF:PixelXDimension", "source": "original:EXIF:PixelXDimension" },
    { "action": "clone", "field": "EXIF:PixelYDimension", "source": "original:EXIF:PixelYDimension" },
    { "action": "clone", "field": "IPTC:Byline", "source": "original:IPTC:Byline" },
    { "action": "clone", "field": "IPTC:Copyright", "source": "original:IPTC:Copyright" },
    { "action": "clone", "field": "IPTC:CopyrightNotice", "source": "original:IPTC:CopyrightNotice" },
    { "action": "clone", "field": "XMP:Creator", "source": "original:XMP:Creator" },
    { "action": "clone", "field": "XMP:Rights", "source": "original:XMP:Rights" }
  ]
}
```

No match condition (unconditional). Each clone pulls the original value captured at pipeline start, so upstream plugin modifications do not affect what gets restored.

### Manifest

```json
{
  "identifier": "photo.quigs.metadata-sanitizer",
  "name": "Metadata Sanitizer",
  "pluginSchemaVersion": "1",
  "type": "mutable"
}
```

No config entries, no binary, no dependencies, no consumed fields.

### File Layout

```
~/.config/piqley/plugins/photo.quigs.metadata-sanitizer/
├── manifest.json
└── stage-post-process.json
```

### Behavior

1. Pipeline reaches post-process stage
2. Rule 1 fires unconditionally: `removeField: "*"` wipes all file metadata from the MetadataBuffer
3. Rule 2 fires unconditionally: 17 clone write actions restore allowed fields from the `original:` namespace
4. MetadataBuffer flushes to disk, writing the sanitized metadata back to the image files
5. If an allowed field was not present on the original image (e.g., no IPTC:Byline), the clone is a no-op for that field

### Edge Cases

- **Missing fields**: If the original image lacks a field in the allowlist, clone resolves to nil and no field is written. The image simply won't have that field.
- **Non-string values**: Clone preserves the original JSONValue type (string, array, number). No type coercion.
- **Multiple images**: Rules are evaluated per-image. Each image gets its own wipe-and-restore cycle.
