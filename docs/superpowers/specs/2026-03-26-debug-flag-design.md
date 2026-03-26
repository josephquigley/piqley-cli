# Debug Flag Design Spec

## Summary

Add a `--debug` boolean flag to the CLI that gets passed through to plugins via both JSON payload and environment variable, following the exact same pattern as `--dry-run`.

## Motivation

Plugins sometimes need to emit extra diagnostic information. Rather than each plugin inventing its own debug mechanism, a standard `--debug` flag passed from the CLI gives plugins a consistent way to determine whether to show debug output.

## Design

### CLI Layer (piqley-cli)

**ProcessCommand.swift**: Add a `@Flag` property:

```swift
@Flag(help: "Enable debug output from plugins")
var debug = false
```

Pass `debug` to `PipelineOrchestrator.run()`.

### Pipeline Layer (piqley-cli)

**PipelineOrchestrator.swift**: Add `debug: Bool` parameter to `run()` and include it in `HookContext`:

```swift
struct HookContext {
    let dryRun: Bool
    let debug: Bool
    // ... other fields
}
```

### Plugin Execution Layer (piqley-cli)

**PluginEnvironment.swift**: Add constant:

```swift
static let debug = "PIQLEY_DEBUG"
```

**PluginRunner.swift**:
- `buildEnvironment()`: Set `env[PluginEnvironment.debug] = debug ? "1" : "0"`
- `buildJSONPayload()`: Include `debug` in the JSON payload

### Core Types (piqley-core)

**PluginInputPayload.swift**: Add property:

```swift
public let debug: Bool
```

### Plugin SDK (piqley-plugin-sdk)

**plugin-input.schema.json**: Add field:

```json
"debug": { "type": "boolean" }
```

**Request.swift**: Add property to `PluginRequest`:

```swift
public let debug: Bool
```

With documentation comment explaining that when `true`, plugins should emit additional diagnostic information.

### Documentation (piqley-plugin-sdk)

**Debug.md**: Add a documentation page (mirroring DryRun.md) showing how to use the flag in both JSON protocol and pipe protocol plugins:

- JSON/SDK plugins: check `request.debug`
- Pipe protocol plugins: check `$PIQLEY_DEBUG == "1"`

## Scope

This spec covers only the plumbing: getting the flag from CLI to plugins. What plugins do with it is up to each plugin author. The documentation will show the recommended pattern.

## Testing

- Unit tests for `buildEnvironment()` and `buildJSONPayload()` confirming `debug` is included
- Integration test confirming `--debug` flag is accepted by the CLI
