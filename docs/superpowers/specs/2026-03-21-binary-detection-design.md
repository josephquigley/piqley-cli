# Binary Detection and Protocol Auto-Configuration -- Design Spec

## Summary

Add automatic detection of whether a plugin binary is a piqley SDK plugin or a regular CLI tool. The SDK responds to a `--piqley-info` probe argument. The CLI probes binaries in the command wizard (for auto-configuration) and at pipeline start (for validation). Protocol mismatches, missing binaries, and non-executable files abort the pipeline before any images are processed.

## Motivation

When configuring a plugin binary, the user must manually set the protocol to `json` (for SDK plugins) or `pipe` (for CLI tools like `exiftool`, `sips`). Getting this wrong causes confusing failures: a CLI tool receiving JSON on stdin ignores it; the pipeline sees no `result` line and treats it as a critical failure. Automatic detection eliminates this class of errors.

Additionally, there is no validation that a configured binary actually exists or is executable. Broken configs are only discovered mid-pipeline after some plugins have already modified images.

---

## 1. SDK: `--piqley-info` Probe

### Behavior

The `run()` method in `PiqleyPlugin` (piqley-plugin-sdk) checks `CommandLine.arguments` before reading stdin. If `--piqley-info` is present, it prints a JSON info line to stdout and exits with code 0.

```json
{"piqleyPlugin": true, "schemaVersion": "1"}
```

This is automatic. Plugin authors do not need to implement or opt into anything.

### Implementation

In `Plugin.swift`, at the top of the `run()` extension method:

```swift
if CommandLine.arguments.contains("--piqley-info") {
    let info = #"{"piqleyPlugin":true,"schemaVersion":"1"}"#
    print(info)
    Foundation.exit(0)
}
```

This runs before stdin is read, so it works even when no payload is available.

### Files touched

- `swift/PiqleyPluginSDK/Plugin.swift` in piqley-plugin-sdk

---

## 2. CLI: `BinaryProbe` Utility

### Probe result

```swift
enum BinaryProbeResult {
    case piqleyPlugin(schemaVersion: String)
    case cliTool
    case notFound
    case notExecutable
}
```

### Probe logic

1. Resolve the command path: absolute paths used as-is, relative paths resolved against the plugin directory.
2. Check the file exists. If not, return `.notFound`.
3. Check the file is executable. If not, return `.notExecutable`.
4. Run the binary with `--piqley-info` argument, capture stdout, with a 5-second timeout.
5. Parse stdout as JSON. If it contains `"piqleyPlugin": true`, return `.piqleyPlugin(schemaVersion:)`.
6. Otherwise (no output, non-JSON output, non-zero exit, timeout), return `.cliTool`.

### Files touched

- Create `Sources/piqley/Plugins/BinaryProbe.swift` in piqley-cli

---

## 3. Wizard: Command Entry Validation

### Flow

When the user submits a command path in the command wizard:

1. Resolve the path (relative to plugin dir or absolute).
2. Run `BinaryProbe`.
3. If `.notFound`: show error "Command not found at \<resolved path\>", return to command prompt.
4. If `.notExecutable`: show error "Command exists but is not executable: \<resolved path\>", return to command prompt.
5. If `.piqleyPlugin`: auto-set `pluginProtocol` to `.json`, show confirmation "Detected piqley plugin (schema v\<version\>). Protocol set to JSON."
6. If `.cliTool`: auto-set `pluginProtocol` to `.pipe`, then prompt: "Run once per image (batch), or once for the whole folder?"
   - "Per image" sets `batchProxy` with default sort config.
   - "Whole folder" leaves `batchProxy` as nil.

### Files touched

- Modify `Sources/piqley/Wizard/CommandEditWizard.swift` in piqley-cli

---

## 4. Pipeline: Pre-flight Binary Validation

### Behavior

In `PipelineOrchestrator.run()`, after dependency validation but before executing any hooks, validate all binaries in the pipeline:

1. For each plugin in the pipeline across all hooks, if the stage has a non-empty binary command:
   - Run `BinaryProbe` to check the binary exists and is executable.
   - Compare the probe result against the configured `pluginProtocol`.
2. Abort the pipeline (return false, log error) if any binary fails validation:
   - `.notFound`: "Binary not found for plugin '\<id\>': \<resolved path\>"
   - `.notExecutable`: "Binary not executable for plugin '\<id\>': \<resolved path\>"
   - Protocol mismatch: "Protocol mismatch for plugin '\<id\>': binary is a \<detected type\> but protocol is configured as \<configured protocol\>"

Protocol mismatch cases:
- Probe returns `.piqleyPlugin` but config has `protocol: pipe` (or vice versa: probe returns `.cliTool` but config has `protocol: json`).

### Validation order

Pre-flight validation runs after:
1. Config loading
2. Dependency validation

And before:
1. Temp folder creation
2. Image copying
3. Metadata extraction

This ensures no work is done if the pipeline is broken.

### Files touched

- Modify `Sources/piqley/Pipeline/PipelineOrchestrator.swift` in piqley-cli

---

## 5. Wire Format

No changes to PiqleyCore types. The `--piqley-info` argument is a convention between the SDK and the CLI, not a wire format field. The `pluginProtocol` field on `HookConfig` already exists.

The `BinaryProbe` is a CLI-only utility. The probe result is not persisted anywhere; it is computed on demand in the wizard and at pipeline start.
