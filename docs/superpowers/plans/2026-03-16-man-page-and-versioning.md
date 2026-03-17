# Man Page & Versioning Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a comprehensive roff man page for quigsphoto-uploader and version the codebase at 1.0.0.

**Architecture:** Two deliverables — a hand-crafted `man/quigsphoto-uploader.1` roff file covering all CLI commands, config fields, files, exit codes, and examples; and a one-line version addition to the ArgumentParser CommandConfiguration.

**Tech Stack:** roff/mdoc markup, Swift ArgumentParser

**Spec:** `docs/superpowers/specs/2026-03-16-man-page-and-versioning-design.md`

---

### Task 1: Add version 1.0.0 to CommandConfiguration

**Files:**
- Modify: `Sources/quigsphoto-uploader/QuigsphotoUploader.swift:7-11`

- [ ] **Step 1: Add version parameter**

In `Sources/quigsphoto-uploader/QuigsphotoUploader.swift`, change the `CommandConfiguration` at line 7-11 from:

```swift
static let configuration = CommandConfiguration(
    commandName: "quigsphoto-uploader",
    abstract: "Process and publish photos to Ghost CMS",
    subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self]
)
```

to:

```swift
static let configuration = CommandConfiguration(
    commandName: "quigsphoto-uploader",
    abstract: "Process and publish photos to Ghost CMS",
    version: "1.0.0",
    subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self]
)
```

- [ ] **Step 2: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

Then run: `.build/debug/quigsphoto-uploader --version`
Expected output: `1.0.0`

- [ ] **Step 3: Commit**

```bash
git add Sources/quigsphoto-uploader/QuigsphotoUploader.swift
git commit -m "feat: add version 1.0.0 to CLI"
```

---

### Task 2: Create the man page

**Files:**
- Create: `man/quigsphoto-uploader.1`

- [ ] **Step 1: Create man/ directory and write the man page**

Create `man/quigsphoto-uploader.1` with roff content using the mdoc macro set (standard on macOS/BSD).

Reference the spec at `docs/superpowers/specs/2026-03-16-man-page-and-versioning-design.md` for all content details.

**Roff skeleton — the file must start with this structure:**

```roff
.Dd March 16, 2026
.Dt QUIGSPHOTO-UPLOADER 1
.Os
.Sh NAME
.Nm quigsphoto-uploader
.Nd process and publish photos to Ghost CMS
.Sh SYNOPSIS
.Nm
.Cm process
.Ar folder-path
.Op Fl -dry-run
.Op Fl -verbose-results
.Op Fl -json-results
.Op Fl -results-dir Ar path
.Nm
.Cm setup
.Nm
.Cm clear-cache
.Op Fl -upload-log
.Op Fl -email-log
.Sh DESCRIPTION
(prose here)
.Sh COMMANDS
.Ss process
.Bl -tag -width Ds
.It Fl -dry-run
Preview actions without uploading or emailing.
...
.El
```

**Key mdoc patterns:**
- Sections: `.Sh SECTION NAME`
- Subsections: `.Ss subsection name`
- Tagged lists (use for config fields and flag docs): `.Bl -tag -width Ds` / `.It field-name` / `.El`
- Paths: `.Pa ~/.config/quigsphoto-uploader/config.json`
- Literal text blocks (for JSON examples): `.Bd -literal -offset indent` / `.Ed`
- Backslashes in examples (regex): use `\e` for a literal backslash in roff (e.g., `Sony\es+a\ed+.*`)

The man page must include these sections in order:

1. **NAME** — `quigsphoto-uploader \- process and publish photos to Ghost CMS`

2. **SYNOPSIS** — three usage lines (process with all flags, setup, clear-cache with flags)

3. **DESCRIPTION** — reads exported images from a folder, extracts EXIF metadata (keywords, camera model, title, description), resizes, uploads to Ghost CMS as scheduled posts. Mention: optional 365 Project email via SMTP, two-tier dedup, posts without titles saved as drafts, single-instance process lock, email failures non-fatal.

4. **COMMANDS** — subsections for each:
   - `process <folder-path>` with `--dry-run`, `--verbose-results`, `--json-results`, `--results-dir <path>`
   - `setup` — interactive wizard, writes config.json and Keychain secrets
   - `clear-cache` with `--upload-log`, `--email-log` (no flags = both)

5. **CONFIGURATION** — document `~/.config/quigsphoto-uploader/config.json` with all fields from the spec table:
   - `ghost.url`, `ghost.schedulingWindow` (start, end, timezone), `ghost.non365ProjectFilterTags`
   - `processing.maxLongEdge`, `processing.jpegQuality`
   - `project365.keyword`, `project365.referenceDate`, `project365.emailTo`
   - `smtp.host`, `smtp.port`, `smtp.username`, `smtp.from`
   - `tagBlocklist`, `requiredTags`, `cameraModelTags`
   - Pattern matching subsection: plain string (exact, case-insensitive), `glob:` prefix (wildcards `*` and `?`), `regex:` prefix (full-match semantics)
   - `cameraModelTags` example showing all three pattern types:
     ```
     "Canon EOS R5": ["Canon", "Mirrorless"]
     "glob:*Nikon*": ["Nikon"]
     "regex:Sony\\s+a\\d+.*": ["Sony", "Mirrorless"]
     ```

6. **FILES**
   - `~/.config/quigsphoto-uploader/config.json`
   - `~/.config/quigsphoto-uploader/upload-log.jsonl`
   - `~/.config/quigsphoto-uploader/email-log.jsonl`
   - Keychain services: `quigsphoto-uploader-ghost`, `quigsphoto-uploader-smtp`

7. **EXIT CODES** — 0 (success), 1 (fatal), 2 (partial)

8. **EXAMPLES** — at least these:
   - `quigsphoto-uploader process ~/Photos/export` — basic usage
   - `quigsphoto-uploader process ~/Photos/export --dry-run` — preview
   - `quigsphoto-uploader process ~/Photos/export --json-results --results-dir /tmp/results` — JSON output
   - `quigsphoto-uploader clear-cache --upload-log` — clear specific cache
   - A `cameraModelTags` JSON config snippet

Use the mdoc macros shown in the skeleton above. For the CONFIGURATION section, use `.Bl -tag -width Ds` with `.It` entries for each config field (e.g., `.It ghost.url`). There is no roff table — tagged lists are the standard approach for documenting config fields in man pages.

- [ ] **Step 2: Verify man page renders correctly**

Run: `man -l man/quigsphoto-uploader.1 | head -80`
Expected: Formatted man page output with NAME, SYNOPSIS, and start of DESCRIPTION visible.

Run: `mandoc -Tlint man/quigsphoto-uploader.1 2>&1 || true`
Expected: No errors (warnings are acceptable).

- [ ] **Step 3: Commit**

```bash
git add man/quigsphoto-uploader.1
git commit -m "docs: add comprehensive man page"
```
