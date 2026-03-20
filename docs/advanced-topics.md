# Advanced Topics

This guide walks through real-world piqley workflows: multi-publisher pipelines, composable metadata plugins, cross-plugin state sharing, and automation patterns.

## A Real Workflow: Lightroom to Ghost, Email, and Social Media

This is the workflow that inspired piqley. It starts with a Lightroom export and ends with photos published to a Ghost blog, emailed to a private mailing list, and queued for social media (via Ghost's Zapier hookf), all without manual intervention or processing.

### The Pipeline

```
Lightroom export (full resolution, all metadata)
  │
  ▼
piqley process /path/to/exports
  │
  ▼
pre-process
  ├── privacy-strip          Strip GPS, camera serial, lens serial
  ├── org-keyword-strip      Strip Lightroom organization keywords
  ├── nlp-keyword-strip      Strip Negative Lab Pro keywords
  └── ghost-tagger           Convert keywords → Ghost CMS tags
  │
  ▼
publish
  ├── project365-email       Resize + email to 365 Project list
  ├── ghost-publisher        Resize + schedule #image-post (non-365)
  └── ghost-365-publisher    Resize + schedule #image-post (365 Project)
```

### Pre-Process: Cleaning Metadata

#### Privacy Strip

Export from Lightroom with all metadata so your workflow has access to everything. Then strip what shouldn't be published:

```
~/.config/piqley/plugins/privacy-strip/stage-pre-process.json
```

```json
{
  "preRules": [
    {
      "emit": [
        { "action": "clone", "field": "tags", "source": "original:IPTC:Keywords" }
      ]
    },
    {
      "match": { "field": "original:EXIF:GPSLatitude" },
      "write": [
        { "action": "removeField", "field": "EXIF:GPSLatitude" },
        { "action": "removeField", "field": "EXIF:GPSLongitude" },
        { "action": "removeField", "field": "EXIF:GPSAltitude" },
        { "action": "removeField", "field": "EXIF:GPSDateStamp" },
        { "action": "removeField", "field": "EXIF:GPSTimeStamp" }
      ]
    },
    {
      "write": [
        { "action": "removeField", "field": "EXIF:CameraSerialNumber" },
        { "action": "removeField", "field": "EXIF:LensSerialNumber" },
        { "action": "removeField", "field": "EXIF:BodySerialNumber" }
      ]
    }
  ]
}
```

The first rule clones all original IPTC keywords into this plugin's `tags` field so downstream plugins can read a clean copy. The remaining rules write directly to the image file to strip GPS coordinates, camera serials, and lens identifiers.

#### Organization Keyword Strip

Lightroom organization keywords like "Candidate", "Ready to Publish", or "Project 365" are useful inside your catalog but meaningless to readers:

```
~/.config/piqley/plugins/org-keyword-strip/stage-pre-process.json
```

```json
{
  "preRules": [
    {
      "emit": [
        { "action": "remove", "field": "tags", "values": [
            "Candidate",
            "Ready to Publish",
            "Project 365",
            "glob:Portfolio*"
          ]
        }
      ],
      "write": [
        { "action": "remove", "field": "IPTC:Keywords", "values": [
            "Candidate",
            "Ready to Publish",
            "Project 365",
            "glob:Portfolio*"
          ]
        }
      ]
    }
  ]
}
```

This removes the keywords from both the in-memory state (so downstream plugins don't see them) and the image file (so they're not in the published copy). Glob patterns (`glob:Portfolio*`) catch any keyword starting with "Portfolio".

#### Negative Lab Pro Keyword Strip

If you scan film with Negative Lab Pro, it injects keywords like film chemistry, scanner model, and lens settings. Strip those the same way:

```
~/.config/piqley/plugins/nlp-keyword-strip/stage-pre-process.json
```

```json
{
  "preRules": [
    {
      "emit": [
        { "action": "remove", "field": "tags", "values": [
            "regex:^\\d+\\+\\d+\\+\\d+.*",
            "regex:^\\d+mm\\s+\\d+\\.\\d+f$",
            "glob:plustek*",
            "glob:Epson*",
            "regex:^(HC-110|D-76|Rodinal|XTOL|DD-X).*"
          ]
        }
      ],
      "write": [
        { "action": "remove", "field": "IPTC:Keywords", "values": [
            "regex:^\\d+\\+\\d+\\+\\d+.*",
            "regex:^\\d+mm\\s+\\d+\\.\\d+f$",
            "glob:plustek*",
            "glob:Epson*",
            "regex:^(HC-110|D-76|Rodinal|XTOL|DD-X).*"
          ]
        }
      ]
    }
  ]
}
```

The regex patterns match Negative Lab Pro's conventions:
- `1+1+100` style dilution ratios
- `50mm 2.0f` style lens descriptions
- Scanner brand names
- Common developer chemical names

#### Ghost Tagger

This is where things get interesting. The ghost tagger converts your remaining Lightroom keywords into Ghost CMS tags and adds internal routing tags that tell your publishers what to do:

```
~/.config/piqley/plugins/ghost-tagger/stage-pre-process.json
```

```json
{
  "preRules": [
    {
      "emit": [
        { "action": "clone", "field": "ghost-tags", "source": "privacy-strip:tags" }
      ]
    },
    {
      "emit": [
        { "field": "ghost-tags", "values": [
            "#image-post",
            "#instagram-post",
            "#pixelfed-post"
          ]
        }
      ]
    }
  ]
}
```

Two things are happening:
1. Clone the cleaned tags from the `privacy-strip` plugin's namespace (after organization and NLP keywords have been removed by the earlier plugins).
2. Add internal Ghost tags (prefixed with `#` so Ghost treats them as internal). These routing tags tell the publish-stage plugins which posts to create.

This is a **composability pattern**. The ghost tagger doesn't strip keywords itself. It reads from an upstream plugin's namespace, benefiting from all the cleanup that already happened.

### Publish: Multiple Destinations from One Export

All three publishers read from the same `ghost-tagger:ghost-tags` namespace. They share the tagger's output without duplicating any tag logic.

#### Project 365 Email Publisher

A binary plugin that resizes images for email and sends them to a private mailing list. It checks for the "Project 365" tag in the original keywords (before stripping) to decide which images qualify:

```
~/.config/piqley/plugins/project365-email/stage-publish.json
```

```json
{
  "preRules": [
    {
      "match": { "field": "original:IPTC:Keywords", "pattern": "glob:Project 365" },
      "emit": [
        { "field": "eligible", "values": ["true"] },
        { "action": "clone", "field": "subject", "source": "original:IPTC:ObjectName" },
        { "action": "clone", "field": "body", "source": "original:IPTC:Caption-Abstract" }
      ]
    }
  ],
  "binary": {
    "protocol": "json"
  }
}
```

The pre-rules check the original (un-stripped) keywords for "Project 365", then clone the IPTC Title and Description into fields the binary can read. The binary handles resizing and SMTP. It reads `eligible`, `subject`, and `body` from its input state.

**Secrets:**

```bash
piqley secret set project365-email smtp-password
piqley secret set project365-email recipient-address
```

The binary receives these in its `secrets` payload at runtime.

#### Ghost Publisher (Non-365 Posts)

A binary plugin that resizes images and schedules them as Ghost blog posts. It targets posts that are *not* part of the 365 Project:

```
~/.config/piqley/plugins/ghost-publisher/stage-publish.json
```

```json
{
  "preRules": [
    {
      "emit": [
        { "action": "clone", "field": "tags", "source": "ghost-tagger:ghost-tags" }
      ]
    }
  ],
  "binary": {
    "protocol": "json"
  }
}
```

The binary receives the Ghost tags and the image folder. Its logic:
1. Filter out images with the "Project 365" tag in the original metadata
2. Query the Ghost Admin API for the last scheduled `#image-post` without a "365 Project" tag
3. Extract that post's scheduled date
4. For each image (sorted by creation time), schedule a new post offset by +1 day from the last, at a random time within a configured window

**Secrets:**

```bash
piqley secret set ghost-publisher admin-api-key
piqley secret set ghost-publisher api-url
```

#### Ghost 365 Publisher

Same pattern, but for 365 Project posts specifically:

```
~/.config/piqley/plugins/ghost-365-publisher/stage-publish.json
```

```json
{
  "preRules": [
    {
      "match": { "field": "original:IPTC:Keywords", "pattern": "glob:Project 365" },
      "emit": [
        { "field": "eligible", "values": ["true"] },
        { "action": "clone", "field": "tags", "source": "ghost-tagger:ghost-tags" },
        { "field": "tags", "values": ["365 Project"] }
      ]
    }
  ],
  "binary": {
    "protocol": "json"
  }
}
```

This one checks for the "Project 365" keyword in the original file and adds the "365 Project" tag for Ghost. The binary does the same scheduling logic as the non-365 publisher, but queries for posts that *do* have the "365 Project" tag.

Both Ghost publishers can share the same Ghost Admin API key, or use different ones if they publish to different sites:

```bash
piqley secret set ghost-365-publisher admin-api-key
piqley secret set ghost-365-publisher api-url
```

### The Config

```json
{
  "pipeline": {
    "pre-process": [
      "privacy-strip",
      "org-keyword-strip",
      "nlp-keyword-strip",
      "ghost-tagger"
    ],
    "publish": [
      "project365-email",
      "ghost-publisher",
      "ghost-365-publisher"
    ]
  }
}
```

Order matters in `pre-process`. The privacy strip runs first to clone original tags and remove GPS. The org and NLP strippers clean up those cloned tags. The ghost tagger reads the cleaned result and adds routing tags. By the time the publish stage runs, every publisher sees the same clean, tagged state.

## Composability Patterns

### Shared Pre-Processor, Multiple Publishers

The ghost tagger example above demonstrates the core pattern: one pre-process plugin prepares state that multiple publish plugins consume.

```
ghost-tagger (pre-process)
    ↓ ghost-tagger:ghost-tags
    ├── ghost-publisher (publish)     reads ghost-tagger:ghost-tags
    ├── ghost-365-publisher (publish) reads ghost-tagger:ghost-tags
    └── pixelfed-publisher (publish)  reads ghost-tagger:ghost-tags
```

Each publisher gets the same tags without any of them knowing how tags were cleaned or generated. Swap out the tagger and all publishers update.

### Namespace Isolation

Every plugin gets its own namespace. A plugin named `privacy-strip` writes to `privacy-strip:tags`, `privacy-strip:eligible`, etc. Other plugins read from that namespace with the `clone` action:

```json
{ "action": "clone", "field": "myTags", "source": "privacy-strip:tags" }
```

Two namespaces are reserved. The `original` namespace is populated with the image's file metadata before any plugins run. Plugins can always read `original:EXIF:*` and `original:IPTC:*` fields. The `skip` namespace tracks images that have been excluded from the pipeline via the `skip` action.

### Reading vs. Writing

- **emit** modifies in-memory state. Fast, non-destructive, visible to downstream plugins.
- **write** modifies the image file on disk. Use sparingly; only when you need the change baked into the exported file (stripping GPS, embedding keywords).

A common pattern is to `emit` computed values for downstream plugins and only `write` the final result at the end of the pre-process stage.

## State Flow

State flows forward through the pipeline. Each plugin can read any previous plugin's namespace:

```
Image metadata extracted into "original" namespace
  │
  ▼ pre-process
  privacy-strip    → writes privacy-strip:tags
  org-keyword-strip → reads/modifies privacy-strip:tags
  ghost-tagger     → reads privacy-strip:tags, writes ghost-tagger:ghost-tags
  │
  ▼ publish
  ghost-publisher  → reads ghost-tagger:ghost-tags, original:IPTC:*
```

Binary plugins receive the full state object for every image and can return updated state in their response.

## Conditional Rules

Rules with a `match` block only fire when the pattern matches. Rules without `match` run unconditionally.

### Match any image with GPS data

```json
{
  "match": { "field": "original:EXIF:GPSLatitude" },
  "write": [{ "action": "removeField", "field": "EXIF:GPSLatitude" }]
}
```

Omitting `pattern` matches on field existence. If the field has any value, the rule fires.

### Match a specific keyword

```json
{
  "match": { "field": "original:IPTC:Keywords", "pattern": "glob:Project 365" },
  "emit": [{ "field": "is365", "values": ["true"] }]
}
```

### Match with regex

```json
{
  "match": { "field": "original:EXIF:FocalLength", "pattern": "regex:^(85|105|135)$" },
  "emit": [{ "field": "tags", "values": ["Portrait"] }]
}
```

### Unconditional rule (no match)

```json
{
  "emit": [{ "field": "processed", "values": ["true"] }]
}
```

### Skip an image from the pipeline

The `skip` action halts all processing for the matched image. No further rules, binary execution, or downstream plugins will see the image:

```json
{
  "match": { "field": "original:IPTC:Keywords", "pattern": "glob:*Draft*" },
  "emit": [{ "action": "skip" }]
}
```

Skip is useful for filtering out images that shouldn't be published: drafts, duplicates, already-published photos, or images missing required metadata. Once skipped, the image is excluded from all remaining pipeline stages.

Skip records are tracked globally. Downstream rules can check if the current image was skipped using the special `skip` match field:

```json
{
  "match": { "field": "skip", "pattern": "glob:*" },
  "emit": [{ "field": "status", "values": ["was-skipped"] }]
}
```

Binary plugins receive a `skipped` array in their input payload listing which images were skipped and by which plugin, so they can report or log skipped images if needed.

## Automation

### Hazel (macOS)

Create a Hazel rule that watches your Lightroom export folder:

- **Condition:** Folder contents count is greater than 0
- **Action:** Run shell script

```bash
/opt/homebrew/bin/piqley process "$1" --delete-source-contents --non-interactive
```

`--non-interactive` ensures piqley never blocks waiting for input. `--delete-source-contents` cleans up after a successful run so Hazel doesn't re-trigger.

### Folder-Watching on Linux

Use `inotifywait` or a systemd path unit:

```bash
inotifywait -m -e close_write /path/to/exports/ | while read dir action file; do
  piqley process /path/to/exports --delete-source-contents --non-interactive
done
```

### Dry Run Before Automating

Always test with `--dry-run` first to see what piqley would do without modifying anything:

```bash
piqley process /path/to/exports --dry-run
```

## Plugin Development Tips

### Declarative-Only Plugins

For metadata cleanup and tagging, you often don't need code at all. Create a declarative plugin:

```bash
piqley plugin init
```

Write your rules in the stage files. Test with `--dry-run`. Done.

### Binary Plugins

For anything that needs API calls, image manipulation, or complex logic, scaffold a project:

```bash
piqley plugin create ~/Developer/my-plugin --language swift
```

The SDK handles the JSON protocol. Your plugin just implements a function that receives images and state and returns results.

### Secrets

Never hardcode API keys. Store them in the Keychain:

```bash
piqley secret set my-plugin api-key
```

Your plugin receives secrets in its input payload. The key format is scoped to the plugin name, so `ghost-publisher/admin-api-key` and `ghost-365-publisher/admin-api-key` are separate secrets, even if they hold the same value.

### Editing Rules

Hand-editing JSON is fine, but the TUI editor is faster for iteration:

```bash
piqley plugin rules edit my-plugin
```

Use Ctrl+L to browse available metadata fields from a real image.
