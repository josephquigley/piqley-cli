# Metadata Engine Design — DRAFT

**Status:** In progress — Sections 1-7 reviewed, remaining sections TBD

## Overview

Re-introduce EXIF keyword scanning, filtering, and mapping as a shared capability in piqley. Piqley core owns an in-memory metadata store that serves as global shared state for plugins. Plugins read and write metadata through declarative manifest configurations, and piqley brokers all metadata access.

**Approach:** Internal metadata engine module within the existing Swift package (`Sources/piqley/Metadata/`), with clean architectural boundaries.

---

## Section 1: In-Memory Metadata Store

Piqley core extracts EXIF/IPTC/XMP from each image at pipeline start and populates a `MetadataStore` — a per-image, namespaced dictionary held in memory for the pipeline's lifetime.

**Namespaces:**
- `original:*` — populated by core at extraction time using native tag paths as field names. Read-only to plugins. No transformation (no keyword flattening, etc.).
- `<plugin>:*` — each plugin owns its namespace. Only that plugin can write to it.
- `aggregate:*` — computed by core after each plugin runs. Represents the latest value for each field across the full call stack. Later plugins overwrite earlier ones. Always available to every plugin implicitly.

**Example original namespace after extraction:**
```
original:IPTC:Keywords        → ["Nashville", "Sunset", "Animals > Cats > Tabby"]
original:IPTC:ObjectName      → "Nashville Sunset"
original:IPTC:CaptionAbstract → "Golden hour at Shelby Bottoms"
original:EXIF:DateTimeOriginal → "2026:03:15 18:42:00"
original:TIFF:Make             → "Canon"
original:TIFF:Model            → "Canon EOS R5"
original:EXIF:LensModel        → "RF 24-70mm F2.8L"
```

**Aggregate computation:** After each plugin completes, core walks the plugin execution order and merges each plugin's namespace on top of `original:*`. Last writer wins per field. Null values are treated as deletions.

---

## Section 2: Plugin Manifest Extensions

The plugin `manifest.json` gains three new sections:

### `dependencies`

Declares what namespaces/fields the plugin reads. Validated at startup — errors if the referenced plugin isn't in the pipeline or runs later.

```json
{
  "dependencies": ["hashtag"]
}
```

Can reference a full namespace or specific fields (e.g., `"hashtag:keywords"`).

### `metadataOutputs`

Declares what fields the plugin writes to its own namespace. Used for dependency validation.

```json
{
  "metadataOutputs": ["keywords", "hashtags"]
}
```

### `metadataFileMapping`

Declares fork/restore behavior for plugins that need metadata written into image files.

```json
{
  "metadataFileMapping": {
    "beforeExecution": {
      "mappings": {
        "original:*": "*",
        "hashtag:keywords": "IPTC:Keywords"
      }
    },
    "afterExecution": {
      "mappings": {
        "IPTC:Keywords": "keywords",
        "EXIF:GPSLatitude": "gpsLat"
      }
    }
  }
}
```

- `piqley:` prefix is implicit throughout — never appears in manifest mappings.
- `original` namespace uses native tag paths as field names, no transformation.
- `beforeExecution`: left = store field, right = native tag to write. `*` = use field name as tag. Sources are merged with later entries in the mapping winning on conflict.
- `afterExecution`: left = native tag to read from file, right = field name stored under `<plugin>:*`.
- Available to any plugin regardless of protocol, optional for all.
- `aggregate` is always available — usable in mappings without declaring it in `dependencies`.

---

## Section 3: Plugin Data Flow

### 1. Startup — dependency resolution
Core parses all manifests, builds a dependency graph from `dependencies`. Validates that every referenced namespace/field has a provider that runs earlier in the pipeline. Fails fast with a clear error if the graph is broken or circular.

### 2. Pipeline start — extraction
Core copies images to temp folder, reads all EXIF/IPTC/XMP from each image, populates the `original:*` namespace in the in-memory store using native tag paths as field names. No transformation.

### 3. Per plugin — metadata delivery
- **JSON protocol:** Resolved metadata from declared `dependencies` plus `aggregate` included in the JSON payload. Plugin returns modifications in its JSON response under a `metadata` key.
- **Pipe protocol:** Metadata not delivered via environment variables. Pipe plugins use `metadataFileMapping` for file-level metadata access, or convert to JSON protocol for structured access.
- **`metadataFileMapping` (either protocol):** Piqley forks images to a scratch directory, runs `beforeExecution` mappings (merging sources, writing native tags), plugin operates on forked files, piqley runs `afterExecution` extraction from the output files.

### 4. Per plugin — store update
Core writes plugin outputs to `<plugin>:*` in the store, then recomputes `aggregate:*` by walking the execution order and merging each plugin's namespace (last writer wins per field).

### 5. Pipeline end
Store is discarded. The images in the temp folder retain whatever metadata they had from the source files (unless a plugin deliberately modified them via `metadataFileMapping`).

---

## Section 4: Aggregate Namespace

The `aggregate` namespace is a computed view that core rebuilds after each plugin completes. It represents the cumulative state of all plugin outputs in execution order.

**Computation:**
```
Start with original:* as base
Layer keyword-flattener:* on top → overwrite matching fields, add new ones
Layer hashtag:*            on top → overwrite matching fields, add new ones
Layer privacy-guard:*      on top → overwrite matching fields, add new ones
...and so on for each plugin that has run
```

Last writer wins per field.

**Use case:** A publish plugin that just wants "the final keywords" without caring which plugin produced them uses `aggregate:IPTC:Keywords` in its mappings instead of referencing specific plugin namespaces.

**No declaration needed:** `aggregate` is always available to every plugin. Using it in mappings or JSON payload does not require listing it in `dependencies`.

**Combining with explicit dependencies:**
```json
{
  "dependencies": ["hashtag"],
  "metadataFileMapping": {
    "beforeExecution": {
      "mappings": {
        "aggregate:IPTC:Keywords": "IPTC:Keywords"
      }
    }
  }
}
```
`dependencies: ["hashtag"]` adds a startup validation guarantee that hashtag is present and runs first. `aggregate` gives the latest accumulated state.

**Field deletion:** A plugin writes a null/sentinel value to a field in its namespace. Core treats null values as deletions during aggregate computation.

---

## Section 5: Metadata Engine Module

The metadata engine lives in `Sources/piqley/Metadata/` as an internal architectural boundary within the existing package.

**Key types:**

- **`MetadataStore`** — per-pipeline-run container. Holds namespaced metadata per image. Responsible for namespace ownership enforcement (only the owning plugin can write), aggregate recomputation, and null-as-deletion semantics.

- **`MetadataExtractor`** — reads EXIF/IPTC/XMP from image files using `ImageIO`/`CGImageSource`. Populates `original:*` using native tag paths as field names. No transformation.

- **`MetadataMapper`** — executes `metadataFileMapping` declarations. Handles forking images to a scratch directory, writing `beforeExecution` mappings to native tags, and reading `afterExecution` tags back into the store.

- **`DependencyResolver`** — parses `dependencies` and `metadataOutputs` from all manifests at startup. Validates the graph against pipeline order. Reports missing providers, ordering violations, or undeclared outputs.

**Integration with `PipelineOrchestrator`:**
The orchestrator calls into the metadata engine at four points:
1. After image copy → `MetadataExtractor` populates `original:*`
2. Before each plugin → deliver resolved metadata (JSON payload), run `beforeExecution` fork if declared
3. After each plugin → write outputs to store, run `afterExecution` extraction if declared, recompute aggregate
4. Pipeline end → store discarded

---

## Section 6: JSON Protocol Payload Changes

The existing `PluginInputPayload` gains a `metadata` field:

```json
{
  "hook": "post-process",
  "folderPath": "/tmp/piqley-abc123/",
  "pluginConfig": { "...": "..." },
  "secrets": { "...": "..." },
  "executionLogPath": "/path/to/execution.jsonl",
  "dryRun": false,
  "metadata": {
    "images": {
      "IMG_001.jpg": {
        "original:IPTC:Keywords": ["Nashville", "Sunset"],
        "original:TIFF:Model": "Canon EOS R5",
        "aggregate:IPTC:Keywords": ["Nashville", "Sunset", "#Canon"],
        "hashtag:hashtags": ["#Nashville", "#Sunset", "#Canon"]
      }
    }
  }
}
```

Only fields from declared `dependencies` plus `aggregate` are included — plugins don't see namespaces they didn't ask for.

**Plugin JSON response** gains a `metadata` key for writing back:

```json
{
  "type": "result",
  "success": true,
  "metadata": {
    "images": {
      "IMG_001.jpg": {
        "keywords": ["Nashville", "Sunset", "Flattened"],
        "hashtags": ["#Nashville", "#Sunset"]
      }
    }
  }
}
```

Response fields are written to `<plugin>:*` — no namespace prefix needed in the response since the plugin can only write to its own namespace.

---

## Section 7: Pipe Protocol Metadata Delivery

Pipe protocol plugins do not receive metadata through environment variables or arg substitution. Two options for pipe plugins that need metadata:

1. **`metadataFileMapping`** — declare `beforeExecution` mappings to get metadata written into forked image files, and `afterExecution` to extract results back.
2. **Convert to JSON protocol** — for plugins that need structured read/write access to the store.

---

## Remaining Sections (TBD)

- Error handling and validation
- Dry-run behavior (blocked keyword visibility, metadata diff output)
- Bundled plugins (keyword-flattener, blocklist, camera-model tagger)
- Testing strategy
- Migration path from old `_migrate/` code
