# State Engine Design

**Status:** Approved

## Overview

Add a per-pipeline-run, in-memory state store to piqley. Core extracts image metadata into a read-only `original` namespace, and JSON protocol plugins read from declared dependencies and write to their own namespace. Plugins declare dependencies in their manifest; piqley validates ordering at startup and delivers only requested state in the JSON payload.

**Non-goals (explicitly deferred):**
- Aggregate/computed namespaces
- File forking or metadata-to-EXIF write-back
- Metadata file mapping
- Pipe protocol state access

---

## Section 1: State Store

A per-pipeline-run, in-memory store. Namespaced per image, per plugin.

**Structure:**
```
StateStore
  └── images: [String: ImageState]                    // keyed by filename
        └── namespaces: [String: [String: JSONValue]] // keyed by namespace name
```

**Namespaces:**
- `original` — populated by core at extraction time. Read-only to plugins.
- `<plugin-name>` — owned by that plugin. Only that plugin can write.

**Namespace ownership is implicit, not validated.** A plugin's response keys are always written into its own namespace verbatim. If a plugin writes `"foo-plugin:title"`, that becomes a key named `foo-plugin:title` inside the plugin's own namespace — core does not parse or split on colons. There is no error path for "writing to another namespace" because it's structurally impossible.

**Lifecycle:**
1. Pipeline start → core extracts EXIF/IPTC/XMP → populates `original` for each image
2. Before each JSON plugin → core reads declared dependencies from store, includes in payload
3. After each JSON plugin → core writes returned state into `<plugin>:*`
4. Pipeline end → store discarded

---

## Section 2: Plugin Manifest Extensions

The manifest gains one new field:

### `dependencies`

An array of plugin names whose state this plugin needs to read.

```json
{
  "dependencies": ["hashtag"]
}
```

**Reserved names:** `original` is a valid dependency that is always satisfied (it is populated by core, not a plugin). No user plugin may be named `original`.

**Validation at startup:**
- Every dependency (except `original`) must reference a plugin that exists in the pipeline
- Every dependency must run before the declaring plugin. "Runs before" means the dependency appears in an earlier hook (per canonical hook ordering: pre-process → post-process → publish → schedule → post-publish), or in the same hook at an earlier array index.
- Circular dependencies are impossible since pipeline order is linear
- Missing or misordered dependency → fail fast with clear error

No other manifest changes. No `metadataOutputs`, no `metadataFileMapping`.

---

## Section 3: JSON Protocol Changes

### Input payload

The existing `PluginInputPayload` gains a `state` field:

```json
{
  "hook": "publish",
  "folderPath": "/tmp/piqley-abc123/",
  "pluginConfig": { "url": "..." },
  "secrets": { "api-key": "..." },
  "executionLogPath": "/path/to/execution.jsonl",
  "dryRun": false,
  "state": {
    "IMG_001.jpg": {
      "original": {
        "IPTC:Keywords": ["Nashville", "Sunset", "Animals > Cats > Tabby"],
        "EXIF:DateTimeOriginal": "2026:03:15 18:42:00",
        "TIFF:Model": "Canon EOS R5"
      },
      "hashtag": {
        "hashtags": ["#Nashville", "#Sunset", "#Canon"]
      }
    }
  }
}
```

Only `original` plus declared `dependencies` namespaces are included. A plugin with no dependencies and no `"original"` in its dependency list does not receive `state` at all — the field is omitted from the payload.

### Plugin response

The `result` line gains an optional `state` field. Keys are written verbatim into the plugin's namespace:

```json
{
  "type": "result",
  "success": true,
  "state": {
    "IMG_001.jpg": {
      "hashtags": ["#Nashville", "#Sunset", "#Canon"],
      "caption": "Golden hour at Shelby Bottoms"
    }
  }
}
```

Core stores this under the plugin's namespace. For a plugin named `hashtag`, this becomes:
```
hashtag:hashtags  → ["#Nashville", "#Sunset", "#Canon"]
hashtag:caption   → "Golden hour at Shelby Bottoms"
```

**`state` is optional** in both directions — plugins that don't need state ignore it, plugins that don't produce state omit it.

**Partial image responses:** If a plugin's response omits an image from its `state` object, no state is stored for that image under that plugin's namespace. State keys that don't match any image in the temp folder are silently ignored.

**Multi-hook invocations:** If the same plugin runs in multiple hooks, each invocation fully replaces that plugin's namespace for each image present in the response. Keys from a prior invocation that are absent in the new response are removed.

---

## Section 4: Metadata Extraction

At pipeline start, after copying images to the temp folder, core reads EXIF/IPTC/XMP from each image and populates the `original` namespace.

- Keys follow `CGImageSource` property dictionary structure, flattened to `Group:Tag` format (e.g., `IPTC:Keywords`, `EXIF:DateTimeOriginal`, `TIFF:Model`). The group names correspond to `CGImageProperty` dictionary keys (`{IPTC}` → `IPTC`, `{Exif}` → `EXIF`, `{TIFF}` → `TIFF`, etc.).
- Implemented using `ImageIO`/`CGImageSource` (available on macOS)
- Extraction happens once, before any plugin runs
- If an image has no readable metadata, its `original` namespace is an empty object

**No write-back.** Core never writes state back into image files. If a plugin needs to modify actual EXIF/IPTC tags on disk, that's the plugin's responsibility using the files in the temp folder.

---

## Section 5: Module Structure

The state engine lives in `Sources/piqley/State/` with three types:

- **`StateStore`** — per-pipeline-run container. Dictionary of image filenames → dictionary of namespaces → arbitrary JSON values. Methods: `setNamespace(image:plugin:values:)`, `resolve(image:dependencies:)` (returns only requested namespaces).

- **`MetadataExtractor`** — reads EXIF/IPTC/XMP from image files, returns dictionary of native tag paths → values. Called once per image at pipeline start to populate `original`.

- **`DependencyValidator`** — at startup, takes all manifests + pipeline order, checks every declared dependency exists and runs earlier. Returns error describing the problem or success.

**Integration with `PipelineOrchestrator`:**
1. After image copy → `MetadataExtractor` populates `original` for each image
2. Before each JSON plugin → `StateStore.resolve()` builds the `state` payload from declared dependencies
3. After each JSON plugin → `StateStore.setNamespace()` stores returned state
4. Pipeline end → store discarded

---

## Example: Hashtag → Flickr Pipeline

**hashtag plugin** (`manifest.json`):
```json
{
  "name": "hashtag",
  "dependencies": ["original"],
  "hooks": {
    "post-process": { "command": "./hashtag-gen", "protocol": "json" }
  }
}
```

Receives `original:IPTC:Keywords` → generates hashtags → returns:
```json
{
  "type": "result",
  "success": true,
  "state": {
    "IMG_001.jpg": {
      "hashtags": ["#Nashville", "#Sunset", "#Cats"]
    }
  }
}
```

**flickr plugin** (`manifest.json`):
```json
{
  "name": "flickr",
  "dependencies": ["hashtag"],
  "hooks": {
    "publish": { "command": "./flickr-publish", "protocol": "json" }
  }
}
```

Receives `hashtag:hashtags` in its state payload, adds its own (e.g., `#FlickrDaily`), and uses them when calling the Flickr API. No state return needed.
