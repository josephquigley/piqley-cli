# Upstream Field Discovery for Rules Editor

**Date:** 2026-03-24

## Problem

The rules editor only shows `original`, `self`, and `read` namespaces. It cannot display fields from other plugins in the workflow because the current implementation scans installed plugin manifests for `valueEntries`, which are config entries (like `base-url`), not emitted state fields. Plugins that emit state via rules (e.g. `IPTC:Keywords`) are invisible to the rules editor for downstream plugins.

## Design

Discover available plugin namespaces and their fields by scanning the rules JSON files of upstream plugins in the same workflow. "Upstream" is determined by pipeline stage ordering and position within a stage.

### Upstream Resolution

Given a target plugin at stage S, position P in the workflow pipeline:

1. All plugins in stages that execute before S (per `registry.executionOrder`) are upstream.
2. Plugins in stage S with array index < P are upstream.
3. The target plugin itself is included, so its own previously-emitted fields are visible.

### Field Harvesting

For each upstream plugin (and self), load its rules files from the workflow rules directory:

```
~/.config/piqley/workflows/{workflow}/rules/{pluginId}/stage-*.json
```

For each stage JSON file, scan `preRules` and `postRules` arrays. Collect every unique `emit[].field` value. These become the available fields under that plugin's namespace in the rules editor.

Fields are only harvested from emit actions that write to the plugin's namespace (i.e. `emit[].field`, not `write[].field` which writes to file metadata).

### Scope

**What changes:**

1. **`FieldDiscovery`**: new static method that takes the workflow, target plugin ID, stage registry, and workflow rules base path. Computes upstream plugins + self, scans their rules JSON files, returns `[DependencyInfo]`.
2. **`PluginRulesCommand`** (lines 61-82): replace the "scan all installed plugins" block with a call to the new discovery method.
3. **Tests**: verify upstream ordering, same-stage ordering, self-inclusion, and correct field extraction from rules JSON.

**What does NOT change:**

- `FieldDiscovery.buildAvailableFields` (still takes `[DependencyInfo]` and builds the fields dictionary).
- `RuleEditingContext`, `RulesWizard`, or any wizard UI code.
- The manifest schema. No new fields needed.
- The `original`, `read`, and `self` namespace handling.

### Example

Workflow `quigs.photo` pipeline:
```
pre-process: [photo.quigs.negativelabpro.sanitizer]
publish:     [photo.quigs.ghostcms.publisher]
```

When editing rules for `photo.quigs.ghostcms.publisher` (stage: `publish`):
- Upstream: `photo.quigs.negativelabpro.sanitizer` (stage `pre-process` is before `publish`)
- Self: `photo.quigs.ghostcms.publisher`
- Scan rules for sanitizer: `stage-pre-process.json` has `preRules[0].emit[0].field = "IPTC:Keywords"`
- Result: namespace `photo.quigs.negativelabpro.sanitizer` with field `IPTC:Keywords` is available in the rules editor

### Limitations

- Only discovers fields produced by rules, not by plugin binaries. A binary that emits state fields without corresponding rules will not be discovered. This can be addressed later with an optional manifest `emits` field if needed.
- If no rules have been written for an upstream plugin yet, its namespace will not appear (no rules to scan).
