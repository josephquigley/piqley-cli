# Plan: Autocomplete Arrow Key Navigation

**Spec:** `docs/superpowers/specs/2026-03-26-autocomplete-arrow-navigation-design.md`

## Steps

### Step 1: Add arrow state variables

**File:** `Sources/piqley/Wizard/Terminal.swift` (line ~329)

Add after `lastTabQuery`:
- `var arrowIndex: Int? = nil` — currently arrow-selected suggestion (nil = no selection)
- `var scrollOffset = 0` — start index into matchedIndices for visible window

### Step 2: Update suggestion display to use arrowIndex and scrollOffset

**File:** `Sources/piqley/Wizard/Terminal.swift` (lines 359-371)

Replace the suggestion rendering loop:
- Compute `visibleStart = scrollOffset`, `visibleEnd = min(scrollOffset + maxSuggestions, matches.count)`
- Slice `matchedIndices[visibleStart..<visibleEnd]` for display
- Determine which display index gets the `Tab →` marker:
  - If `arrowIndex` is set: marker on the item at `arrowIndex - scrollOffset`
  - If `arrowIndex` is nil: marker on `tabCycleIndex % matchedIndices.count - scrollOffset` (if visible, else index 0)
- Update "... N more" to reflect `matches.count - visibleEnd`

### Step 3: Handle cursorUp and cursorDown in the key switch

**File:** `Sources/piqley/Wizard/Terminal.swift` (after line 402)

Add cases:
- `.cursorDown`: if matches not empty, set `arrowIndex = (arrowIndex ?? -1) + 1`, clamped to `matchedIndices.count - 1`. If `arrowIndex >= scrollOffset + maxSuggestions`, increment `scrollOffset`.
- `.cursorUp`: if `arrowIndex != nil`, decrement. If it goes below `scrollOffset`, decrement `scrollOffset`. Clamp at 0.

### Step 4: Update Tab handler to respect arrowIndex

**File:** `Sources/piqley/Wizard/Terminal.swift` (lines 403-414)

Modify the `.tab` case:
- If `arrowIndex` is set: use `matchedIndices[arrowIndex!]` for the completion, set `tabCycleIndex = arrowIndex! + 1`, clear `arrowIndex`.
- If `arrowIndex` is nil: existing cycling behavior.

### Step 5: Reset arrowIndex on text input

**File:** `Sources/piqley/Wizard/Terminal.swift` (lines 391-398)

In `.char` and `.backspace` cases, add `arrowIndex = nil` and `scrollOffset = 0`.

### Step 6: Build and verify

Run `swift build` to confirm compilation.
