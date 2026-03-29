# Image Outcome Enum Design

## Summary

Replace the `success: Bool` field on image results with a `status: ImageOutcome` enum supporting four states: `success`, `failure`, `warning`, and `skip`. This is a breaking change across all three repos (piqley-core, piqley-plugin-sdk, piqley-cli).

## Motivation

Plugins currently have no way to skip individual images at runtime. The only options are success or failure. A plugin that encounters an unsupported image format must either lie (report success) or mislead (report failure for something that isn't an error). Adding `skip` and `warning` gives plugins a way to express what actually happened.

## New Type: ImageOutcome (PiqleyCore)

```swift
public enum ImageOutcome: String, Codable, Sendable {
    case success
    case failure
    case warning
    case skip
}
```

Defined in PiqleyCore so it's shared across the CLI and SDK.

## Wire Format Change

The `imageResult` JSON line changes from:

```json
{"type": "imageResult", "filename": "photo.jpg", "success": true}
```

to:

```json
{"type": "imageResult", "filename": "photo.jpg", "status": "success"}
```

The `error` field remains unchanged. Any status can optionally include it:

```json
{"type": "imageResult", "filename": "photo.jpg", "status": "skip", "error": "not a RAW file"}
```

## PluginOutputLine Change (PiqleyCore)

The `success: Bool?` field becomes `status: ImageOutcome?` for `imageResult` lines. The `result` line type continues to use `success: Bool?` for overall plugin success/failure. All other fields are unchanged.

## SDK API Change (PiqleyPluginSDK)

`reportImageResult` changes from:

```swift
public func reportImageResult(_ filename: String, success: Bool, error: String? = nil)
```

to:

```swift
public func reportImageResult(_ filename: String, outcome: ImageOutcome, message: String? = nil)
```

The parameter is named `outcome` (not `status`) to avoid confusion with HTTP/process status. The `message` parameter maps to the `error` field on the wire.

Usage:

```swift
request.reportImageResult("photo.jpg", outcome: .success)
request.reportImageResult("photo.jpg", outcome: .failure, message: "corrupt file")
request.reportImageResult("photo.jpg", outcome: .warning, message: "missing GPS data")
request.reportImageResult("photo.jpg", outcome: .skip, message: "not a RAW file")
```

## SDK Test Support Changes

`ImageResult` struct updates: `success: Bool` becomes `outcome: ImageOutcome`. `CapturedOutput.imageResults` updates to decode `status` into `ImageOutcome`.

## CLI Changes

### PluginRunner.readJSONOutput()

Reads `status` instead of `success`. Debug log includes the status string:

```
[plugin-name] imageResult: photo.jpg status=skip
```

### Skip Record Creation

When the CLI receives an imageResult with `status: "skip"`, it creates a `SkipRecord` the same way rule-based skips do today. The `message` (if provided) is not stored in the `SkipRecord` since that struct only holds `file` and `plugin`.

### Warning Handling

Warning results are logged but don't affect pipeline flow. They are treated like success for the purpose of "did this image get processed": no skip record, pipeline continues.

## JSON Schema Update

In `plugin-output.schema.json`, the imageResult definition replaces:

```json
"success": {"type": "boolean"}
```

with:

```json
"status": {"type": "string", "enum": ["success", "failure", "warning", "skip"]}
```

## Scope

This is a breaking change. All three repos need updates:

- **piqley-core:** `ImageOutcome` enum, `PluginOutputLine` field change
- **piqley-plugin-sdk:** `reportImageResult` API change, test support types, JSON schema
- **piqley-cli:** `PluginRunner` parsing, skip record creation on `skip` status
