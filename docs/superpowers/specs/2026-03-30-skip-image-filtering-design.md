# Skip Image Filtering Design

## Problem

When a plugin reports an image as skipped (via `reportImageResult(_, outcome: .skip)`), the image is added to the pipeline's global `skippedImages` set. This correctly prevents rule evaluation for that image in subsequent stages. However, the plugin binary still receives the skipped image in two ways:

1. **Image folder**: The skipped image file remains in the working directory. The plugin's `imageFiles()` returns it, so the plugin processes it without any rule-emitted fields (like `is_feature_image`), producing incorrect results.
2. **State payload**: The skipped image's state is included in the JSON payload sent to the plugin binary, reinforcing the impression that the image should be processed.

### Observed behavior

Running the `quigs.photo-365-project` workflow:

- Date Tools skips `roll82` and `roll101` in `pre-process` (end_date before start_date).
- Ghost CMS Publisher in `publish` still processes both images. Because the `is_feature_image = "true"` rule was never evaluated (correctly skipped), the plugin defaults to `false` and publishes the images with inline images instead of feature images.

The images should not reach the Ghost CMS Publisher binary at all.

## Design

Two changes in the CLI's pipeline orchestrator, both in `runPluginHook` after pre-rule evaluation and before binary execution.

### 1. Remove skipped image files from the image folder

After pre-rules produce the final `skippedImages` set, delete any skipped image files from `imageFolderURL` before calling `runBinary`. This ensures the plugin's `imageFiles()` never returns them.

**Location**: `PipelineOrchestrator.swift`, in `runPluginHook`, between the pre-rules block and the binary execution block (after line 279, before line 281).

```swift
// Remove skipped images from the image folder so the binary never sees them
for imageName in skippedImages {
    let imageURL = imageFolderURL.appendingPathComponent(imageName)
    try? FileManager.default.removeItem(at: imageURL)
}
```

Using `try?` because the file may already have been removed by a previous stage's plugin. This is expected and not an error.

### 2. Filter skipped images from the state payload

Pass `skippedImages` to `buildStatePayload` and exclude those image names from the state dictionary.

**Location**: `PipelineOrchestrator+Helpers.swift`, `buildStatePayload`.

Add a `skippedImages: Set<String> = []` parameter. In the iteration loop, skip image names present in the set:

```swift
for imageName in await stateStore.allImageNames {
    if skippedImages.contains(imageName) { continue }
    // ... existing resolve and append logic
}
```

Update the call site in `runBinary` to pass the current `skippedImages`.

### What doesn't change

- The SDK, plugins, and PiqleyCore are untouched.
- Skip records remain in the state store for diagnostics and logging.
- The "skip binary entirely if all images are skipped" optimization continues to work.
- Rule evaluation skip logic (in `evaluateRuleset`) is unchanged.

## Edge cases

- **File already removed**: A previous stage's plugin may have already removed the file. `try?` handles this silently.
- **Fork vs main temp**: When `shouldFork` is false, `imageFolderURL` may be the main temp directory. Removing skipped files there is correct because skips are global and permanent: no downstream plugin should process a globally skipped image.
- **Non-image files**: Only image files matching `TempFolder.imageExtensions` would be relevant. The removal targets files by name from the `skippedImages` set, which only contains image filenames.

## Testing

- Unit test: verify that `buildStatePayload` excludes skipped image names.
- Integration test: a pipeline with two stages where plugin A skips an image in stage 1, and plugin B in stage 2 should not see that image in its `imageFiles()` or state payload.
