# Blocklist Pattern Matching Design

**Date:** 2026-03-16
**Status:** Approved

## Problem

The tag blocklist in `tagBlocklist` only supports exact string matching. Users need glob and regex patterns to block keywords by convention (e.g., all keywords starting with `_`) without listing each one individually.

## Design

### Pattern Syntax

Blocklist entries use a prefix convention within the existing `tagBlocklist` JSON array:

- **Plain string** → exact match (e.g., `"WIP"`)
- **`glob:` prefix** → simple glob with `*` (any chars) and `?` (single char) (e.g., `"glob:_*"`)
- **`regex:` prefix** → regex pattern (e.g., `"regex:^DSC\\d+$"`)

All matching is **case-insensitive**.

Example config:
```json
{
  "tagBlocklist": ["WIP", "glob:_*", "regex:^DSC\\d+$"]
}
```

### Architecture: TagMatcher Protocol

A `TagMatcher` protocol with three implementations:

```
protocol TagMatcher
├── ExactMatcher   — case-insensitive string equality
├── GlobMatcher    — fnmatch with lowercased inputs
└── RegexMatcher   — Swift Regex with case-insensitive flag
```

Each matcher has a `description` property for dry-run output (e.g., `"exact: WIP"`, `"glob: _*"`).

A factory function `TagMatcher.buildMatchers(from:)` parses the `[String]` config into `[TagMatcher]`, throwing on invalid regex at startup.

### Keyword Filtering

`ImageMetadata.processKeywords` changes signature from `blocklist: [String]` to `blocklist: [TagMatcher]`.

A new `ImageMetadata.filterKeywords` method returns a `KeywordFilterResult` with both kept and blocked keywords (including which matcher caused each block), used by dry-run output.

```swift
struct KeywordFilterResult {
    let kept: [String]
    let blocked: [(keyword: String, matcher: String)]
}
```

### Dry Run Enhancement

The existing `--dry-run` flag on `process` is enhanced to log blocklist filtering per image:

```
[IMG_001.jpg] Keywords: Nashville, Nature, 365 Project
[IMG_001.jpg] Blocked: _internal (glob: _*), WIP (exact: WIP)
[IMG_001.jpg] Would schedule: "365 Project #42"
```

Blocked keyword logging only occurs during `--dry-run` — no overhead in normal runs.

### Data Flow

1. `ProcessCommand.run()` loads config, calls `TagMatcher.buildMatchers(from: config.tagBlocklist)` — invalid regex fails fast
2. For each image, calls `ImageMetadata.filterKeywords(raw, blocklist: matchers)` (dry run) or `ImageMetadata.processKeywords(raw, blocklist: matchers)` (normal)
3. Dry run logs blocked keywords with matcher descriptions; normal run proceeds as before

## Files Changed

| File | Change |
|------|--------|
| **New:** `Sources/.../ImageProcessing/TagMatcher.swift` | Protocol, 3 implementations, factory, `KeywordFilterResult` |
| **Edit:** `Sources/.../ImageProcessing/ImageMetadata.swift` | Accept `[TagMatcher]`, add `filterKeywords` |
| **Edit:** `Sources/.../CLI/ProcessCommand.swift` | Build matchers at startup, use `filterKeywords` in dry run |
| **Edit:** `Sources/.../CLI/SetupCommand.swift` | Update prompt to mention `glob:`/`regex:` prefixes |
| **New:** `Tests/.../TagMatcherTests.swift` | Tests for all matchers, factory, and filterKeywords |
| **Edit:** `Tests/.../MetadataReaderTests.swift` | Update to use `[TagMatcher]` |
| **Edit:** `docs/guides/ghost-cms-setup.md` | Document pattern syntax |

## Testing

- ExactMatcher: case-insensitive matching
- GlobMatcher: `*` and `?` wildcards
- RegexMatcher: valid patterns match, invalid regex throws
- Factory: prefix parsing, error handling
- filterKeywords: kept/blocked split with mixed matchers
- Existing tests updated for new signature
