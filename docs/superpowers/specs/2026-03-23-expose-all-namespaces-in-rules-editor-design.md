# Expose All Namespaces in TUI Rules Editor

**Date:** 2026-03-23
**Status:** Approved
**Scope:** piqley-cli (primary), PiqleyCore (minor: add `ReservedName.read` constant)

## Problem

The TUI rules editor currently only exposes namespaces from a plugin's declared dependencies. Users editing per-plugin rules cannot reference fields from installed plugins that aren't explicit dependencies. This is too restrictive: a user may want to match or emit fields from any installed plugin, regardless of build-time dependency declarations.

## Solution

Expand `PluginRulesCommand` to scan all installed plugin manifests (not just declared dependencies) when building the available fields for the rules editor. Add save-time validation that warns when rules reference namespaces from plugins that aren't declared dependencies, with a confirmation prompt to proceed.

## Design

### 1. PluginRulesCommand: scan all installed plugins

**Current behavior:** `PluginRulesCommand.run()` iterates `manifest.dependencyIdentifiers`, loads each dependency's manifest, and builds `FieldDiscovery.DependencyInfo` entries only for those plugins.

**New behavior:** Scan all directories in `PipelineOrchestrator.defaultPluginsDirectory`. For each directory with a valid manifest, build a `DependencyInfo` entry from its `valueEntries`. Include the plugin being edited as well (it may want to reference fields it emitted in an earlier stage). Use `try?` to silently skip directories with missing or malformed manifests, matching the existing error handling pattern. Pass the full set to `FieldDiscovery.buildAvailableFields` as before.

Additionally, pass the original `manifest.dependencyIdentifiers` as a `Set<String>` to `RulesWizard` so it can distinguish dependencies from non-dependencies at save time.

### 2. RulesWizard: save-time validation with warning

**New stored property:** `dependencyIdentifiers: Set<String>`, injected via the initializer.

**Save flow change:** Before writing to disk, the `save()` method:

1. Collects all plugin namespaces referenced by rules across all stages and slots.
2. Filters out built-in namespaces using `ReservedName.original` and `ReservedName.read` (see PiqleyCore change below).
3. Compares the remainder against `dependencyIdentifiers`.
4. If any referenced namespace is not a dependency, displays a warning listing the non-dependency namespaces and prompts "Save anyway? (y/n)".
5. If the user confirms, proceeds with save. If the user declines, cancels the save and returns to the editor.

### 3. Namespace extraction from rules

To identify which plugin namespaces are referenced:

- Parse `rule.match.field`: split on the first `:` to extract the namespace prefix (e.g., `"original:EXIF:ISO"` yields `"original"`).
- Parse `emit.source` on clone actions in both `rule.emit` and `rule.write` arrays: same split logic.
- Collect all extracted namespaces into a `Set<String>`.

This logic lives as a private helper in `RulesWizard` (or a `RulesWizard+UI` extension).

### 4. FieldSelection label update

In `RulesWizard+FieldSelection.swift`, the source description for non-built-in namespaces changes from `"dependency plugin"` to `"plugin"`, since sources now include all installed plugins, not just dependencies.

## Files Changed

**piqley-core:**

| File | Change |
|------|--------|
| `Sources/PiqleyCore/Constants/ReservedName.swift` | Add `ReservedName.read` constant. |

**piqley-cli:**

| File | Change |
|------|--------|
| `Sources/piqley/CLI/PluginRulesCommand.swift` | Scan all installed plugin dirs instead of only dependencies. Pass dependency set to RulesWizard. |
| `Sources/piqley/Wizard/RulesWizard.swift` | Add `dependencyIdentifiers` property. Update init signature. |
| `Sources/piqley/Wizard/RulesWizard+UI.swift` | Add namespace extraction helper. Add save-time validation with warning/confirmation prompt. |
| `Sources/piqley/Wizard/RulesWizard+FieldSelection.swift` | Change "dependency plugin" label to "plugin". |

## Testing

- Unit test: namespace extraction from rules with various field formats (match fields, emit clone sources, write clone sources).
- Unit test: filtering logic correctly excludes built-in namespaces and computes the delta against dependency identifiers.
- Manual TUI test: verify all installed plugins appear as source options.
- Manual TUI test: verify save warns when referencing a non-dependency namespace.
- Manual TUI test: verify save proceeds without warning when all namespaces are dependencies or built-ins.
