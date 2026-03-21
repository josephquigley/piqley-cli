# Pipeline Lifecycle Hooks and Run ID Design

## Summary

Add a pipeline run ID and lifecycle hooks so plugins can distinguish between per-run transient state and persistent state. The CLI generates a UUID per pipeline run, passes it to plugins, and invokes `pipeline-start` and `pipeline-finished` hooks at the boundaries of each run.

## Motivation

Plugins that cache query results (e.g. Ghost CMS caching a "most recent post" query) need to clear transient data between pipeline runs while preserving persistent data (e.g. upload deduplication cache). Without a run ID or lifecycle hooks, plugins have no way to know when a new run starts.

## Changes

### PiqleyCore

**Hook enum**: add two new hooks to the canonical order:

- `pipeline-start` (runs before `pre-process`)
- `pipeline-finished` (runs after `post-publish`)

Canonical order becomes: `pipeline-start`, `pre-process`, `post-process`, `publish`, `post-publish`, `pipeline-finished`.

**PluginInputPayload**: add a `pipelineRunId` field (String, UUID format). Included in every hook invocation within the same pipeline run.

### CLI (PipelineOrchestrator)

1. Generate a UUID at the start of each pipeline run.
2. Pass `pipelineRunId` in the JSON payload for all hooks.
3. Set `PIQLEY_PIPELINE_RUN_ID` environment variable for pipe protocol plugins.
4. Execute `pipeline-start` hook before `pre-process` for all plugins that have a `stage-pipeline-start.json`.
5. Execute `pipeline-finished` hook after `post-publish` for all plugins that have a `stage-pipeline-finished.json`. This hook runs even if the pipeline partially failed (best-effort cleanup).

### Plugin SDK (Swift)

Add `pipelineStart` and `pipelineFinished` cases to the `Hook` enum in the SDK. Add `pipelineRunId` accessor to `PluginRequest`.

### Workflow files

The new hooks appear in workflow pipeline definitions:

```json
{
  "pipeline": {
    "pipeline-start": [],
    "pre-process": [],
    "post-process": [],
    "publish": ["photo.quigs.ghostcms"],
    "post-publish": [],
    "pipeline-finished": ["photo.quigs.ghostcms"]
  }
}
```

### Per-run data convention

Plugins that need per-run transient storage should use `data/runs/<pipelineRunId>/`. The `pipeline-finished` hook is the natural place to clean up this directory. The CLI does not manage this directory; it is the plugin's responsibility.

Persistent data (e.g. upload cache) stays in `data/` as before.

## Files to modify

### piqley-core
- `Sources/PiqleyCore/Hook.swift` - add `pipelineStart`, `pipelineFinished` to enum and canonical order
- `Sources/PiqleyCore/Payload/PluginInputPayload.swift` - add `pipelineRunId: String?` field

### piqley-cli
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift` - generate run ID, execute lifecycle hooks
- `Sources/piqley/Plugins/PluginRunner.swift` - pass run ID in environment
- `Sources/piqley/Config/Workflow.swift` - default empty workflow includes the two new hooks

### piqley-plugin-sdk
- `swift/PiqleyPluginSDK/Plugin.swift` - add hook cases
- `swift/PiqleyPluginSDK/Request.swift` - expose `pipelineRunId`
