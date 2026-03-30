# Last Executed Version Persistence

## Problem

`PluginInputPayload` carries a `lastExecutedVersion` field, but the CLI always sends `nil`. Plugins have no way to know which version of themselves last ran, which blocks schema migrations, data format upgrades, and other version-dependent initialization logic.

## Design

### Storage location

A new file `version-state.json` alongside the plugin manifest at `~/.config/piqley/plugins/<id>/version-state.json`. This keeps CLI-managed state separate from the plugin's `data/` directory (which the plugin binary owns).

Format:

```json
{
  "lastExecutedVersion": "1.2.0"
}
```

A new constant `PluginFile.versionState` in PiqleyCore holds the filename.

### VersionStateStore protocol

```swift
protocol VersionStateStore: Sendable {
    func lastExecutedVersion(for pluginIdentifier: String) -> SemanticVersion?
    func save(version: SemanticVersion, for pluginIdentifier: String) throws
}
```

This protocol allows tests to inject an in-memory implementation instead of hitting the filesystem.

### FileVersionStateStore

The concrete implementation. Takes a `pluginsDirectory: URL` at init. Reads and writes `<pluginsDirectory>/<id>/version-state.json`. Missing files or decode failures return `nil` (treat as first run).

### InMemoryVersionStateStore

A test double backed by a `[String: SemanticVersion]` dictionary.

### Read path

`PluginRunner.buildPayload` receives a `VersionStateStore` parameter. It calls `store.lastExecutedVersion(for: plugin.identifier)` and passes the result as the `lastExecutedVersion` argument instead of the current hardcoded `nil`.

### Write path

In `PipelineOrchestrator.runPluginHook`, after a stage completes with `.success` or `.warning`, the orchestrator checks whether the stage name equals `StandardHook.pipelineStart.rawValue` (`"pipeline-start"`). If so, it calls `store.save(version: pluginVersion, for: pluginIdentifier)`.

The version saved is the plugin's current `pluginVersion` from its manifest (falling back to `0.0.0` if nil, matching the existing behavior in `buildPayload`).

### Pipeline-start as the version gate

The `pipeline-start` stage is the designated place for plugins to perform version-dependent initialization: schema migrations, data format upgrades, cache invalidation, or any other work that must happen once per version change before the main processing stages run.

The CLI updates `lastExecutedVersion` after a successful `pipeline-start` so that:
- The plugin receives the previous version during `pipeline-start` and can compare it to `pluginVersion` to decide whether migration is needed.
- Subsequent stages in the same run receive the now-current version as `lastExecutedVersion` (though in practice, plugins that need it will have already acted in `pipeline-start`).
- If `pipeline-start` fails, the version is not updated, so the migration will be retried on the next run.

### Error handling

- `FileVersionStateStore.lastExecutedVersion` returns `nil` on any read or decode failure (file missing, corrupt JSON, etc.). This is the same as a first run.
- `FileVersionStateStore.save` throws on write failure. The orchestrator logs a warning but does not abort the pipeline, since a missing version update is recoverable (the plugin will just see the old `lastExecutedVersion` on the next run and re-run its migration logic).

### Tests

All tests use `InMemoryVersionStateStore`. No filesystem access.

1. **Read returns nil for unknown plugin.** A fresh store returns `nil` for any identifier.
2. **Write then read round-trips.** Save `1.2.0` for plugin `"foo"`, read it back, assert equality.
3. **Overwrite replaces previous version.** Save `1.0.0`, then save `2.0.0`, read returns `2.0.0`.
4. **buildPayload passes stored version.** Given a store with a saved version, assert the built payload's `lastExecutedVersion` matches.
5. **buildPayload passes nil when no version stored.** Given an empty store, assert the payload's `lastExecutedVersion` is nil.
6. **Orchestrator saves version after successful pipeline-start.** Run a plugin through `pipeline-start` with `.success`, assert the store contains the plugin's version.
7. **Orchestrator does NOT save version after other stages.** Run a plugin through `pre-process` with `.success`, assert the store is still empty.
8. **Orchestrator does NOT save version on pipeline-start failure.** Run a plugin through `pipeline-start` with `.critical`, assert the store is still empty.

### Doc updates

- **`docs/architecture/plugin-system.md`**: Add a note to the `lastExecutedVersion` row in the PluginInputPayload table explaining that the CLI persists this value after successful `pipeline-start` completion.
- **`docs/plugin-sdk-guide.md`**: Add a section on version migrations explaining that `pipeline-start` is the stage for schema/version/upgrade work, with a code example comparing `lastExecutedVersion` to `pluginVersion`.
