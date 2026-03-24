# Self Namespace Resolution in Rule Evaluator

**Date:** 2026-03-24

## Problem

When writing rules by hand (outside the wizard), users must specify the full plugin namespace for every field reference, e.g. `photo.quigs.ghostcms:schedule_offset`. This is verbose and error-prone. The template resolver already supports `self` as a namespace alias, but the rule evaluator does not.

## Design

Resolve `"self"` and bare (no-colon) field names to the owning plugin's identifier at rule **compile time** in `RuleEvaluator.init`, so the rest of the evaluation path is unchanged.

### Resolution Rules

Given `pluginId: String?` passed into `RuleEvaluator.init`:

| Input field string | Resolved namespace | Resolved field |
|---|---|---|
| `skip` (no colon, regardless of pluginId) | `""` | `skip` |
| `schedule_offset` (no colon, pluginId set) | `pluginId` | `schedule_offset` |
| `schedule_offset` (no colon, pluginId nil) | `""` | `schedule_offset` |
| `self:schedule_offset` (pluginId set) | `pluginId` | `schedule_offset` |
| `self:schedule_offset` (pluginId nil) | compile error | - |
| `original:EXIF:ISO` | `original` | `EXIF:ISO` |
| `read:EXIF:ISO` | `read` | `EXIF:ISO` |

Note: `"self"`, `"original"`, `"read"`, and `"skip"` are reserved namespace names and must not be used as plugin identifiers.

### Scope

**Match side:** `splitField` on `rule.match.field` (line 52) receives `pluginId` and applies resolution.

**Emit side:** Emit fields (`EmitConfig.field`) are already self-scoped by design. They write into the `working` dictionary, which is the plugin's own namespace. No change needed.

**Clone source:** The `splitField` call for clone's `source` (line 168) is left unchanged. Clone sources reference foreign namespaces, so a bare name or `"self"` would be nonsensical. The existing validation error ("clone source must be 'namespace:field'") handles this correctly.

### Changes

1. **`RuleEvaluator.init`**: add `pluginId: String?` parameter.
2. **`splitField`**: add `pluginId: String?` parameter. Precedence:
   1. No colon + `field == "skip"`: return `("", "skip")` regardless of pluginId.
   2. No colon + pluginId set: return `(pluginId, field)`.
   3. No colon + pluginId nil: return `("", field)` (existing behavior).
   4. Namespace is `"self"` + pluginId set: substitute pluginId.
   5. Namespace is `"self"` + pluginId nil: throw compilation error (in nonInteractive mode, log warning and skip rule).
3. **Match-side `splitField` call** (line 52): pass `pluginId`.
4. **Clone-side `splitField` call** (line 168): unchanged, no `pluginId`.
5. **Call site** in `PipelineOrchestrator+Helpers.swift`: pass `ctx.pluginIdentifier` to `RuleEvaluator.init`.
6. **Tests**: cover bare name, `self:field`, fully-qualified names, `skip`, and nil pluginId fallback.

### What Does NOT Change

- `evaluate()` signature and behavior. Its existing `pluginId` parameter serves a different purpose (skip record tracking) and remains.
- `CompiledRule` structure.
- Emit action compilation (fields are already self-scoped).
- Clone source resolution.
- Template resolver (already has its own `self` support).
- The wizard (already produces fully-qualified names).
