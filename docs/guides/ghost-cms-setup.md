# Using quigsphoto-uploader with Ghost CMS

This guide covers setting up Ghost CMS integration, including authentication, configuration, scheduling, deduplication, and tags.

## Creating a Ghost Admin API Key

1. Log in to your Ghost Admin panel (e.g., `https://quigs.photo/ghost/`).
2. Go to **Settings > Integrations**.
3. Click **Add custom integration**.
4. Name it something like "quigsphoto-uploader".
5. Ghost will generate an **Admin API Key**. Copy it -- you will need it during setup.

The Admin API key is a string in the format `<id>:<secret>`. Keep it safe; it provides full write access to your Ghost instance.

## Running quigsphoto-uploader setup

Run `quigsphoto-uploader setup` to walk through configuration interactively. It writes non-secret values to `~/.config/quigsphoto-uploader/config.json` and stores secrets in the macOS Keychain.

### Config Values

**Ghost settings:**

| Value | Description | Example |
|-------|-------------|---------|
| `ghost.url` | Your Ghost site URL. | `https://quigs.photo` |
| `ghost.schedulingWindow.start` | Earliest time of day to schedule posts. | `08:00` |
| `ghost.schedulingWindow.end` | Latest time of day to schedule posts. | `10:00` |
| `ghost.schedulingWindow.timezone` | Timezone for the scheduling window. | `America/New_York` |

**Image processing:**

| Value | Description | Default |
|-------|-------------|---------|
| `processing.maxLongEdge` | Maximum pixel length of the longest edge after resize. Images smaller than this are not upscaled. | `2000` |
| `processing.jpegQuality` | JPEG compression quality (1-100). | `80` |

**365 Project (optional):**

| Value | Description | Example |
|-------|-------------|---------|
| `project365.keyword` | The EXIF keyword that marks a photo as a 365 Project entry. Case-sensitive. | `365 Project` |
| `project365.referenceDate` | The start date for day numbering. Day 1 is the day after this date. | `2025-12-25` |
| `project365.emailTo` | Email address to send 365 Project photos to. | `user@365project.example` |

**SMTP (required for 365 Project email):**

| Value | Description |
|-------|-------------|
| `smtp.host` | SMTP server hostname. |
| `smtp.port` | SMTP server port (typically 587 for STARTTLS). |
| `smtp.username` | SMTP login username. |
| `smtp.from` | Sender address for outgoing emails. |

**Tag blocklist:**

| Value | Description | Example |
|-------|-------------|---------|
| `tagBlocklist` | List of EXIF keywords to exclude from Ghost tags. Matched against leaf node of hierarchical keywords. | `["PersonalOnly", "Draft", "WIP"]` |

### Secrets

These are stored in the macOS Keychain, not in the config file:

- **Ghost Admin API key** -- Keychain service: `quigsphoto-uploader-ghost`
- **SMTP password** -- Keychain service: `quigsphoto-uploader-smtp`

## How Scheduling Works

quigsphoto-uploader maintains two independent scheduling queues in Ghost:

1. **365 Project posts** -- posts tagged `365 Project`
2. **Non-365 Project posts** -- posts tagged `#image-post` but not `365 Project`

For each queue independently:

- If no posts are currently scheduled, check the most recent published post's date. If it was published today, schedule for tomorrow. Otherwise, schedule for today.
- If scheduled posts exist, take the furthest-out scheduled date and add one day.
- The scheduled time is a random time within your configured scheduling window and timezone.

This means a 365 Project post and a non-365 post can be scheduled for the same day -- they do not block each other.

Posts without a title are created as **drafts** instead of being scheduled. They will not publish automatically until you add a title in Ghost Admin.

## How Deduplication Works

quigsphoto-uploader uses a two-tier approach to avoid uploading the same image twice.

### Tier 1: Local Cache

The file `~/.config/quigsphoto-uploader/upload-log.jsonl` records every successful upload. Before uploading an image, quigsphoto-uploader checks this log for a filename match. If found, the upload is skipped with no API call.

### Tier 2: Ghost API Fallback

If the filename is not in the local cache (for example, on a new machine or after clearing the cache), quigsphoto-uploader queries the Ghost Admin API. It checks published, scheduled, and draft posts going back up to one year, looking for a matching filename in the `feature_image` URL.

If a match is found in Ghost but not in the local cache, the cache is updated (self-healing) and the image is skipped.

### Important Notes

- If the Ghost API dedup query fails, quigsphoto-uploader treats this as a **fatal error** and exits. It will not risk creating duplicate posts.
- Dedup is filename-based. If Lightroom exports two different photos with the same filename in different runs, the second will be incorrectly skipped. This is a known limitation, but unlikely in practice.

## How Tags Work

### EXIF Keywords to Ghost Tags

quigsphoto-uploader reads IPTC Keywords from each image's metadata. These become Ghost tags on the post.

**Hierarchical keywords:** If Lightroom writes hierarchical keywords like `Location > USA > Nashville`, quigsphoto-uploader extracts only the leaf node (`Nashville`). The blocklist is matched against the leaf node.

**Tag blocklist:** Any keyword whose leaf node appears in `tagBlocklist` is excluded. Use this for Lightroom-only organizational tags you do not want published.

**Internal tags:** Two internal Ghost tags are always appended to every post:
- `#image-post` -- marks the post as created by quigsphoto-uploader
- `#photo-stream` -- used for photo stream display on the site

Internal tags (prefixed with `#`) are not visible to readers on your Ghost site.

**Auto-creation:** Ghost automatically creates any tag that does not already exist when it appears in a post payload. You do not need to pre-create tags in Ghost Admin.

## Understanding upload-log.jsonl

The file at `~/.config/quigsphoto-uploader/upload-log.jsonl` is an append-only log of every successful Ghost upload. Each line is a JSON object:

```json
{"filename": "IMG_1234.jpg", "ghostUrl": "https://quigs.photo/p/...", "postId": "...", "timestamp": "2026-03-16T09:30:00Z"}
```

This file serves as the primary dedup cache. It uses atomic appends (`O_APPEND`) so concurrent processes (if the lock were bypassed) would not corrupt it.

You can safely delete this file if needed. On the next run, cache misses will fall through to the Ghost API for dedup, and the cache will self-heal by re-adding entries for any matches found in Ghost.
