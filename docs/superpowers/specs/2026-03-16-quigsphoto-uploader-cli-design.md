# piqley CLI — Design Spec

## Overview

`piqley` is a Swift CLI tool that processes photos exported from Lightroom, creates web-friendly versions, uploads them to Ghost CMS with scheduled publishing, and optionally emails 365 Project photos to a bespoke address. It is invoked by Hazel when new photos land in a watched macOS folder.

## Architecture Context

```
Lightroom → Export to folder → Hazel watches folder → piqley CLI
                                                          ↓
                                                    Ghost CMS (scheduling, source of truth)
                                                          ↓ (once published, external service)
                                                    Pixelfed, Instagram, BlueSky

Also from piqley:
  → 365 Project email (after Ghost upload succeeds)

Out of scope (no-ops, context only):
  - Glass.photo (Lightroom plugin, direct upload)
  - Pixelfed, Instagram, BlueSky (Ghost crosspost)
  - quigs.photo website (Ghost publish destination)
```

## CLI Interface

### Commands

**`piqley process <folder-path>`**
- Processes all JPEG images in the given folder
- `--dry-run`: preview actions without uploading or emailing
- `--verbose-results`: include successful images in result output (default: only errors and duplicates)
- `--json-results`: write a single `.piqley-results.json` instead of individual text files
- `--results-dir <path>`: directory to write result files to (default: input folder)
- `--help`: detailed usage information
- Exits with error if config file does not exist (directs user to run `setup`)

**`piqley setup`**
- Interactive walkthrough that prompts for all config values
- Writes config to `~/.config/piqley/config.json`
- Stores secrets (Ghost Admin API key, SMTP password) in macOS Keychain via `SecretStore`

### Exit Codes
- 0: success (all images processed without error)
- 1: fatal error (missing config, API unreachable, invalid credentials, dedup query failure)
- 2: partial success (some images had errors)
- Per-image errors are non-fatal: logged, image skipped, processing continues

### Results Files
After processing, writes plain-text result files to the results directory (one filename per line). Results directory defaults to the input folder, overridden by `--results-dir`:

- `<input-folder>/.piqley-failure.txt` — images that had errors
- `<input-folder>/.piqley-duplicate.txt` — images skipped by dedup
- `<input-folder>/.piqley-success.txt` — only written when `--verbose-results` is passed

Files are only created if they have entries. Hazel can match on file existence to trigger per-outcome cleanup rules.

**JSON mode (`--json-results`):** Instead of individual text files, writes a single `.piqley-results.json` to the results directory:
```json
{
  "failures": ["bar.jpg"],
  "duplicates": ["blee.jpg"],
  "successes": ["foo.jpg"]
}
```
`successes` array is only populated when `--verbose-results` is also passed. The three text files are not written in JSON mode.

## Configuration

### Config File: `~/.config/piqley/config.json`

Config is the source of truth at runtime for all non-secret values.

> **Forkability note:** Name-related strings -- binary name, config directory name (`piqley`), keychain service prefix (`piqley-`), result file prefix (`.piqley-`), temp directory name (`piqley`), and logger labels -- should be defined as constants in code so that forks can rebrand by changing values in one place.

```json
{
  "ghost": {
    "url": "https://quigs.photo",
    "schedulingWindow": {
      "start": "08:00",
      "end": "10:00",
      "timezone": "America/New_York"
    }
  },
  "processing": {
    "maxLongEdge": 2000,
    "jpegQuality": 80
  },
  "project365": {
    "keyword": "365 Project",
    "referenceDate": "2025-12-25",
    "emailTo": "user@365project.example"
  },
  "smtp": {
    "host": "smtp.example.com",
    "port": 587,
    "username": "user@example.com",
    "from": "user@example.com"
  },
  "tagBlocklist": ["PersonalOnly", "Draft", "WIP"]
}
```

### Secrets (Keychain)

Accessed via `SecretStore` protocol:
- Ghost Admin API key — service: `piqley-ghost`
- SMTP password — service: `piqley-smtp`

## Image Processing Pipeline

For a given input folder, processing runs in this order:

### 1. Scan & Sort
- Find all `.jpg` / `.jpeg / .jxl` files (case-insensitive) in the folder
- Read EXIF `DateTimeOriginal` from each file
- Sort ascending by date taken
- Images missing `DateTimeOriginal` sort to the end with a warning logged

### 2. Read Metadata (per image)
- **Title:** IPTC `ObjectName` or XMP `dc:title`
- **Description:** IPTC `Caption-Abstract` or XMP `dc:description`
- **Keywords/tags:** IPTC `Keywords`
  - Hierarchical tags (e.g., `Location > USA > Nashville`): extract leaf node only (`Nashville`)
  - Filter through `tagBlocklist` from config (matched against the leaf node, not the original hierarchy string)
  - **365 Project detection:** case-sensitive exact match of the leaf-node keyword against `project365.keyword` config value (default `"365 Project"`)
- **Camera info:** Make, Model, Lens (preserved in output)
- **DateTimeOriginal:** used for sorting and 365 Project day calculation

### 3. Create Web-Friendly Version (per image)
- Resize longest edge to `maxLongEdge` (default 2000px), preserve aspect ratio, no upscaling
- Re-encode at `jpegQuality` (default 80%)
- Strip EXIF: GPS, MakerNote, and other PII fields
- Preserve: Copyright, Camera Make/Model, Lens, DateTimeOriginal
- Write resized image to `<system-temp>/piqley/` directory (cleaned up on exit, after both Ghost uploads and email sending complete; easy to find for manual cleanup if the process is killed)

### 4. Assess Metadata Completeness
- Title present → post will be scheduled
- Title missing → post will be created as **draft** (no scheduled date, no email sent)
- Description and public tags are optional
- Internal tags (`#image-post`, `#photo-stream`) are always added

## Ghost CMS Integration

### Authentication
- Admin API key retrieved from `SecretStore`
- Used to generate short-lived JWT tokens per Ghost Admin API spec

### Deduplication

Two-tier dedup: local cache first, Ghost API fallback.

**Local cache (first pass):**
- `~/.config/piqley/upload-log.jsonl` — append-only JSONL file recording each successful Ghost upload
- Each line: `{"filename": "IMG_1234.jpg", "ghostUrl": "https://quigs.photo/p/...", "postId": "...", "timestamp": "2026-03-16T09:30:00Z"}`
- Check this file first for filename match. If found, skip the image (no API call needed).
- Writes use atomic append (open with `O_APPEND`) so concurrent processes don't stomp each other.

**Ghost API (cache miss fallback):**
- If the filename is not in the local cache, query Ghost Admin API with three separate paginated requests (one per status: `published`, `scheduled`, `draft`), ordered by date desc, checking the `feature_image` URL for filename match
- Stop searching at 1 year ago — duplicates beyond that are acceptable
- If match found in Ghost but not in cache, add to cache (self-healing) and skip the image

**General rules:**
- Known limitation: if Lightroom exports two different photos with identical filenames in separate runs, the second will be incorrectly skipped. This is accepted as unlikely in practice.
- If match found: skip Ghost upload, but **do not skip email check** — the image is added to the email candidate list so the email flow can assess whether it still needs sending (see Email dedup below).
- If Ghost API dedup query fails: treat as **fatal error** (exit, don't risk duplicates)

### Upload & Scheduling (per image, after dedup passes)

1. **Upload image** to Ghost via Images API (`/ghost/api/admin/images/upload/`)
2. **Determine schedule date:**
   - Query Ghost for the latest post in this image's category using Ghost filter syntax:
     - 365 Project: `filter=tag:365+Project`
     - Non-365 Project: `filter=tag:#image-post+tag:-365+Project` (posts created by this tool, excluding 365 Project)
   - If no scheduled posts in that category: check the most recent published post's date. If it is today, use tomorrow. Otherwise, use current date. Cross-category same-day scheduling is acceptable (365 Project and non-365 Project are independent streams).
   - If scheduled posts exist: take the most distant scheduled date, add 1 day
   - Pick a random time within the configured `schedulingWindow` and `timezone`
3. **Create post:**
   - **365 Project posts:**
     - Title: `"365 Project #<day-number>"` where day number = `(DateTimeOriginal - referenceDate) + 1` (day 1 is the first day). If `DateTimeOriginal` is before `referenceDate`, log a warning and use the absolute day count (still +1 based). Based on EXIF `DateTimeOriginal`, not schedule/upload date.
     - Body (plaintext): EXIF title on first line, EXIF description on second line (omit description line if absent)
     - First tag: `365 Project`
   - **Non-365 Project posts:**
     - Title: EXIF title
     - Body (plaintext): EXIF description (if exists)
   - **All posts:**
     - Tags: EXIF keywords (filtered, leaf-only) added first, then `#image-post` and `#photo-stream` appended as internal tags
     - Ghost auto-creates tags that don't exist when included in the post payload
     - Status: `scheduled` if title present, `draft` if title missing

### Post body format
Ghost Admin API requires structured content. Use the `lexical` field with the post content wrapped in Lexical JSON format (Ghost 5.x default). Plaintext content (title/description) is wrapped in minimal Lexical paragraph nodes. The uploaded image is included as an image card in the Lexical document.

## 365 Project Email Flow

**Runs after all Ghost CMS operations for the entire folder are complete.**

For each image tagged "365 Project" that either was successfully posted to Ghost in this run OR was skipped by Ghost dedup (already uploaded in a prior run):

1. **Compose email:**
   - To: `project365.emailTo` from config
   - From: `smtp.from` from config
   - Subject: EXIF title, or image filename if no title
   - Body: EXIF description (or empty if none)
   - Attachment: the web-friendly resized JPEG (1 image per email)
2. **Send via SMTP** using config host/port/username + password from `SecretStore`

Images created as draft (missing title) do not trigger emails. Images skipped by Ghost dedup **do** still go through email dedup — if they're in the upload log but not the email log, the email is retried.

**Email dedup:**
- `~/.config/piqley/email-log.jsonl` — append-only JSONL file recording each successful email send
- Each line: `{"filename": "IMG_1234.jpg", "emailTo": "user@365project.example", "subject": "...", "timestamp": "2026-03-16T09:35:00Z"}`
- Before sending an email, check this log for a filename match. If found, skip sending.
- Atomic append (`O_APPEND`) for concurrency safety
- **Seeding:** If `email-log.jsonl` does not exist, seed it from Ghost by querying all 365 Project-tagged posts (up to 1 year back) and writing their image filenames to the log. This allows rebuilding on a new machine.

## Error Handling

- **Per-image errors are non-fatal:** log error, skip image, continue processing
- **Fatal errors:** missing config, Ghost API unreachable, invalid API key, dedup query failure → exit with error message and non-zero exit code
- **Email errors are non-fatal:** SMTP failures are logged per-image but do not halt processing. On re-run (e.g., Hazel re-triggers), Ghost dedup will skip the upload but the email flow will retry since the image won't be in the email log.
- **Summary logged at end:** `Processed 12 images: 8 scheduled, 2 drafts, 1 duplicate skipped, 1 error`

## Logging

Uses [swift-log](https://github.com/apple/swift-log) for structured logging. Per-image log entries indicate action taken (scheduled, drafted, skipped-duplicate, emailed, errored).

## Dry Run

`--dry-run` flag runs the full pipeline except actual uploads, post creation, and email sending. Logs what would happen for each image.

## Project Structure

```
piqley/
├── Package.swift
├── Sources/
│   └── piqley/
│       ├── main.swift
│       ├── CLI/
│       │   ├── ProcessCommand.swift
│       │   └── SetupCommand.swift
│       ├── Config/
│       │   └── Config.swift
│       ├── Secrets/
│       │   ├── SecretStore.swift          (protocol)
│       │   └── KeychainSecretStore.swift   (macOS implementation)
│       ├── ImageProcessing/
│       │   ├── ImageScanner.swift          (scan folder, sort by date taken)
│       │   ├── ImageProcessor.swift        (protocol for resize/encode)
│       │   ├── CoreGraphicsImageProcessor.swift  (macOS implementation)
│       │   ├── MetadataReader.swift        (protocol for EXIF/IPTC)
│       │   └── CGImageMetadataReader.swift (macOS implementation)
│       ├── Ghost/
│       │   ├── GhostClient.swift           (API client, JWT auth)
│       │   ├── GhostUploader.swift         (image upload, post creation)
│       │   ├── GhostScheduler.swift        (queue query, date/time picking)
│       │   └── GhostDeduplicator.swift     (filename-based dedup)
│       └── Email/
│           └── EmailSender.swift
├── Tests/
│   └── piqleyTests/
└── .agents/
    └── AGENTS.md
```

## Dependencies

### Swift Packages
- `swift-argument-parser` — CLI commands and flags
- `swift-log` — structured logging
- Swift SMTP package (e.g., SwiftSMTP) — email sending

### System Frameworks (macOS only, behind protocols)
- `CoreGraphics` / `CoreImage` — image resizing (`ImageProcessor` protocol)
- `CGImageSource` / `CGImageDestination` — EXIF/IPTC reading and stripping (`MetadataReader` protocol)
- `Security` — Keychain access (`SecretStore` protocol)
- `Foundation` — JSON, networking, file I/O

### Platform Abstractions
Three protocols abstract macOS-specific functionality for future Linux/Docker portability:
- `SecretStore` — secret retrieval and storage
- `ImageProcessor` — image resizing and encoding
- `MetadataReader` — EXIF/IPTC metadata reading

## Future Work (Out of Scope)
- AI-generated alt text for images
- Setting alt text in Ghost CMS
- Linux/Docker implementations of `SecretStore`, `ImageProcessor`, `MetadataReader`

## Concurrency

Only one instance of `piqley process` should run at a time. The tool acquires an advisory file lock (`flock`-style) at `<system-temp>/piqley/piqley.lock` on startup. Advisory locks are automatically released on process exit or crash, so stale locks are not a concern. If the lock is held, exit with an error message. Hazel should be configured to serialize invocations, but the lock is a safety net.

## Network

- HTTP timeout: 30 seconds for Ghost API calls
- No automatic retry on failure — per-image errors are logged and the image is skipped

## File Handling
- Input files are left in place after processing (Hazel handles cleanup)
- Resized images written to `<system-temp>/piqley/`, cleaned up on tool exit (after all uploads and emails complete)

### Local Data Files (`~/.config/piqley/`)
- `config.json` — runtime configuration (created by `setup`)
- `upload-log.jsonl` — append-only log of successful Ghost uploads (used for dedup, self-heals from Ghost API on cache miss)
- `email-log.jsonl` — append-only log of successful email sends (used for email dedup; seeded from Ghost on first run)
