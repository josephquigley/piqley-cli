# Man Page & Versioning Design

## Overview

Add a comprehensive hand-crafted man page for quigsphoto-uploader and version the codebase at 1.0.0.

## Man Page

### File

`man/quigsphoto-uploader.1` — roff/mdoc format, installed by Homebrew via `man1.install`.

### Sections

**NAME** — one-liner: "process and publish photos to Ghost CMS"

**SYNOPSIS** — usage lines for all three subcommands:

```
quigsphoto-uploader process <folder-path> [--dry-run] [--verbose-results] [--json-results] [--results-dir <path>]
quigsphoto-uploader setup
quigsphoto-uploader clear-cache [--upload-log] [--email-log]
```

**DESCRIPTION** — reads exported images from a folder, extracts EXIF metadata (keywords, camera model, title, description), resizes images, uploads to Ghost CMS as scheduled posts. Optionally emails 365 Project entries via SMTP. Two-tier deduplication (local cache + Ghost API fallback) prevents duplicate posts. Posts without titles are saved as drafts. Only one instance can run at a time (enforced by an advisory process lock). Email send failures are non-fatal and do not affect the exit code.

**COMMANDS** — each subcommand documented:

- `process <folder-path>` — main workflow. Flags: `--dry-run`, `--verbose-results`, `--json-results`, `--results-dir <path>`
- `setup` — interactive configuration wizard, writes config.json and Keychain secrets
- `clear-cache` — deletes log caches. Flags: `--upload-log`, `--email-log` (no flags = delete both)

**CONFIGURATION** — full `~/.config/quigsphoto-uploader/config.json` reference:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `ghost.url` | string | yes | — | Ghost site URL |
| `ghost.schedulingWindow.start` | string | yes | — | Window start (HH:MM) |
| `ghost.schedulingWindow.end` | string | yes | — | Window end (HH:MM) |
| `ghost.schedulingWindow.timezone` | string | yes | — | IANA timezone |
| `ghost.non365ProjectFilterTags` | [string] | no | [] | Tags that exclude posts from schedule-date calculation (non-365 posts) |
| `processing.maxLongEdge` | int | yes | — | Max long edge pixels |
| `processing.jpegQuality` | int | yes | — | JPEG quality (1-100) |
| `project365.keyword` | string | yes | — | Keyword marking 365 Project photos |
| `project365.referenceDate` | string | yes | — | Day-numbering reference (YYYY-MM-DD) |
| `project365.emailTo` | string | yes | — | Email recipient for 365 entries |
| `smtp.host` | string | yes | — | SMTP hostname |
| `smtp.port` | int | yes | — | SMTP port |
| `smtp.username` | string | yes | — | SMTP username |
| `smtp.from` | string | yes | — | Sender address |
| `tagBlocklist` | [string] | no | [] | Patterns to exclude keywords from Ghost tags |
| `requiredTags` | [string] | no | [] | Tags always added to every post |
| `cameraModelTags` | {string: [string]} | no | {} | Camera model patterns → Ghost tags |

Pattern matching syntax (used by `tagBlocklist` and `cameraModelTags` keys):

- Plain string — exact match, case-insensitive
- `glob:` prefix — glob with `*` and `?`
- `regex:` prefix — regular expression (full-match semantics; the pattern must match the entire string, not a substring)

`cameraModelTags` example:

```json
{
  "cameraModelTags": {
    "Canon EOS R5": ["Canon", "Mirrorless"],
    "glob:*Nikon*": ["Nikon"],
    "regex:Sony\\s+a\\d+.*": ["Sony", "Mirrorless"]
  }
}
```

**FILES**

- `~/.config/quigsphoto-uploader/config.json` — configuration file
- `~/.config/quigsphoto-uploader/upload-log.jsonl` — upload dedup cache
- `~/.config/quigsphoto-uploader/email-log.jsonl` — email dedup cache
- Keychain service `quigsphoto-uploader-ghost` — Ghost Admin API key
- Keychain service `quigsphoto-uploader-smtp` — SMTP password

**EXIT CODES**

- 0 — all images processed successfully
- 1 — fatal error (missing config, API failure, dedup failure)
- 2 — partial success (some images had errors)

**EXAMPLES** — basic process, dry run, JSON results to custom dir, clearing caches, cameraModelTags config snippet.

## Versioning

Add version 1.0.0 to the tool:

- Add a `--version` flag to the root command via ArgumentParser's `CommandConfiguration.version`
- The version string: `"1.0.0"`

This is a one-line change in `QuigsphotoUploader.swift`:

```swift
static let configuration = CommandConfiguration(
    commandName: "quigsphoto-uploader",
    abstract: "Process and publish photos to Ghost CMS",
    version: "1.0.0",
    subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self]
)
```

## Homebrew Formula Change

The formula needs a line to install the man page:

```ruby
man1.install "man/quigsphoto-uploader.1"
```

This is out of scope for this repo but noted for the formula update.

## Deliverables

1. `man/quigsphoto-uploader.1` — hand-crafted roff man page
2. Version 1.0.0 added to `QuigsphotoUploader.swift` CommandConfiguration
