# Autocomplete Arrow Key Navigation

**Date:** 2026-03-26
**Scope:** `Terminal.promptWithAutocomplete()` in `Sources/piqley/Wizard/Terminal.swift`

## Summary

Add up/down arrow key navigation to the suggestion list in `promptWithAutocomplete()`. Arrows visually highlight a suggestion without changing the input text. Tab commits the highlighted suggestion to the input field.

## Current Behavior

- Up to 5 suggestions displayed below the input field
- First suggestion shown with `Tab →` marker
- Tab cycles through all matched suggestions, replacing input text each time
- Arrow keys are unhandled (left/right move text cursor)

## New Behavior

### New State

- `arrowIndex: Int?` — which visible suggestion is highlighted via arrow keys. `nil` means no arrow selection is active.
- `scrollOffset: Int` — offset into `matchedIndices` for the visible window (enables scrolling beyond 5 items).

### Arrow Keys

- **Down arrow:** Sets `arrowIndex` to 0 if nil, otherwise increments. If it moves past the visible window, scrolls the window down. Wraps or clamps at the end of all matched suggestions.
- **Up arrow:** Decrements `arrowIndex`. If it moves above the visible window, scrolls up. Clamps at 0 (does not wrap to bottom).

### Display

- When `arrowIndex` is set: the `Tab →` marker appears on the suggestion at `arrowIndex` position.
- When `arrowIndex` is nil: the `Tab →` marker appears at the `tabCycleIndex` position (existing behavior, defaults to first suggestion).
- All non-highlighted suggestions are shown dim.

### Tab Behavior

- **When `arrowIndex` is set:** replaces input text with the highlighted suggestion, sets `tabCycleIndex = scrollOffset + arrowIndex`, clears `arrowIndex`.
- **When `arrowIndex` is nil:** advances `tabCycleIndex` and replaces input text (existing cycling behavior).
- Subsequent Tab presses continue cycling from the new `tabCycleIndex` position.

### Reset

- Any character input or backspace: clears `arrowIndex`, resets `scrollOffset` to 0, resets `tabCycleIndex` (existing reset behavior for tab cycling).

### Scrolling

- The visible window shows up to 5 suggestions starting at `scrollOffset`.
- When `arrowIndex` would move outside the visible window, adjust `scrollOffset` to keep the selection visible.
- The "... N more" indicator updates to reflect remaining items below the window.

## Files Changed

- `Sources/piqley/Wizard/Terminal.swift` — `promptWithAutocomplete()` function only.

## Out of Scope

- Footer text changes
- Changes to `selectFromList()` or `selectFromFilterableList()`
- Changes to callers of `promptWithAutocomplete()`
