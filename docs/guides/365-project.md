# 365 Project Guide

This guide covers how piqley handles 365 Project photos, from tagging in Lightroom through Ghost publishing and email delivery.

## What Is 365 Project

A 365 Project is a commitment to take and share one photo per day for a year. piqley has built-in support for this: it detects 365 Project photos by keyword, numbers them automatically, schedules them to Ghost, and emails them to an external service (like 365project.org).

## Tagging Photos in Lightroom

To mark a photo as a 365 Project entry, add the keyword `365 Project` to it in Lightroom before exporting.

The match is **case-sensitive** and checks against the **leaf node** of hierarchical keywords. So `365 Project` works, but `365 project` or `Projects > 365 Project` (with `365 Project` as a child keyword) would both match as long as the leaf node is exactly `365 Project`.

The keyword used for detection is configurable via `project365.keyword` in the config file, but defaults to `365 Project`.

## How Day Numbering Works

Each 365 Project post gets a title in the format `365 Project #<day-number>`. The day number is calculated from two values:

- **Reference date:** configured as `project365.referenceDate` (e.g., `2025-12-25`)
- **Date taken:** the EXIF `DateTimeOriginal` from the photo, not the upload or schedule date

The formula is:

```
day_number = (DateTimeOriginal date - referenceDate) + 1
```

So if your reference date is `2025-12-25` and you take a photo on `2025-12-26`, that is day 1. A photo taken on `2026-03-16` would be day 82.

If `DateTimeOriginal` is before the reference date, piqley logs a warning but still uses the absolute day count (plus 1). This handles edge cases like backdated test shots.

### Post Content

- **Title:** `365 Project #<day-number>` (generated, ignores EXIF title for this purpose)
- **Body:** EXIF title on the first line, EXIF description on the second line. If description is absent, only the title line appears.
- **Tags:** `365 Project` is added as the first tag, followed by any other EXIF keywords (filtered through the blocklist), then the internal tags `#image-post` and `#photo-stream`.

## How Scheduling Works

365 Project posts are scheduled independently from non-365 posts. piqley queries Ghost for the latest 365 Project post (using the `365 Project` tag filter) and schedules the new post for the next available day.

- If no 365 Project posts are currently scheduled, and the most recent published one was today, the new post is scheduled for tomorrow.
- If scheduled posts exist, the new post goes one day after the furthest-out scheduled post.
- The exact time is randomly chosen within your configured scheduling window (e.g., between 08:00 and 10:00 in your timezone).

Posts missing a title in their EXIF metadata are created as **drafts** and are not scheduled. They also do not trigger emails.

## How the Email Feature Works

After all Ghost operations for a batch are complete, piqley sends one email per 365 Project image to the address configured in `project365.emailTo`. This is meant for posting to 365project.org or a similar service that accepts photo submissions by email.

Each email contains:

- **To:** the configured `project365.emailTo` address
- **From:** the configured `smtp.from` address
- **Subject:** the EXIF title, or the filename if no title is present
- **Body:** the EXIF description, or empty if none
- **Attachment:** the web-friendly resized JPEG (one image per email)

### When Emails Are Sent

Emails are sent for images that:

1. Were successfully uploaded to Ghost in this run, OR
2. Were skipped by Ghost dedup (already uploaded previously) but have not yet been emailed

Draft posts (missing title) do **not** trigger emails.

Email failures are non-fatal. If sending fails, the image is not recorded in the email log. On the next run, Ghost dedup will skip the upload, but the email flow will retry since the image is not in the email log.

## Email Deduplication

The file `~/.config/piqley/email-log.jsonl` tracks every successfully sent email. Each line is a JSON object:

```json
{"filename": "IMG_1234.jpg", "emailTo": "user@365project.example", "subject": "...", "timestamp": "2026-03-16T09:35:00Z"}
```

Before sending, piqley checks this log for a filename match. If found, the email is skipped.

### Seeding from Ghost

If `email-log.jsonl` does not exist (for example, on a new machine), piqley seeds it automatically by querying Ghost for all 365 Project-tagged posts from the past year. It writes their image filenames to the log, so already-published photos are not re-emailed.

This means you can set up piqley on a new machine without worrying about a flood of duplicate emails for photos already posted.

## Configuration Reference

All 365 Project configuration lives under the `project365` key in `~/.config/piqley/config.json`:

```json
{
  "project365": {
    "keyword": "365 Project",
    "referenceDate": "2025-12-25",
    "emailTo": "user@365project.example"
  }
}
```

| Key | Description | Default |
|-----|-------------|---------|
| `keyword` | EXIF keyword that identifies 365 Project photos. Case-sensitive, matched against leaf node. | `365 Project` |
| `referenceDate` | The start date for day numbering. Photos taken on this date are day 1. | (no default, must be set) |
| `emailTo` | Email address to send 365 Project photos to. | (no default, must be set) |

SMTP settings (`smtp.host`, `smtp.port`, `smtp.username`, `smtp.from`) and the SMTP password (in Keychain as `piqley-smtp`) must also be configured for email to work. Run `piqley setup` to set all of these.
