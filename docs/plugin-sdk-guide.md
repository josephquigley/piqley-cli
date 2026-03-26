# Plugin Development with the SDK

When declarative rules aren't enough (you need API calls, image manipulation, or complex logic), build a binary plugin. The [piqley plugin SDK](https://github.com/josephquigley/piqley-plugin-sdk) handles all the communication with piqley so you can focus on your plugin's logic.

This guide covers the Swift SDK. Python, Node.js, and Go SDKs follow the same concepts.

## Scaffold a Project

```bash
piqley plugin create ~/Developer/my-plugin --language swift
```

This generates a ready-to-build Swift package with the SDK dependency wired up.

## The Plugin Protocol

A plugin is a single binary that handles one or more pipeline stages. The SDK dispatches each stage invocation to your `handle` method with a `PluginRequest` whose `hook` property tells you which stage is running. Branch on the hook to separate your logic:

```swift
@main
struct MyPlugin: PiqleyPlugin {
    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        switch request.hook {
        case .preProcess:
            return try await preProcess(request)
        case .postProcess:
            return try await postProcess(request)
        case .publish:
            return try await publish(request)
        case .postPublish:
            return try await postPublish(request)
        }
    }

    private func preProcess(_ request: PluginRequest) async throws -> PluginResponse {
        // TODO: Pre-process logic
        return .ok
    }
    // ... similar for other hooks

    static func main() async {
        await MyPlugin().run()
    }
}
```

Call `run()` from your entry point. The SDK reads the request from stdin, calls your `handle` method, and writes the response to stdout. You never deal with JSON parsing or the communication protocol directly.

## Multi-Stage Plugins

A single plugin binary can participate in multiple pipeline stages. Register the plugin in each stage's slot in your pipeline config, and the orchestrator will invoke the same binary once per stage. Your `handle` method receives a different `hook` value each time, so you branch on it to run the appropriate logic.

This is useful when a plugin needs to do preparation in pre-process and then act on that preparation in publish. For example, a watermark plugin might analyze images in pre-process (checking dimensions, selecting watermark placement) and then apply the watermark in publish. The plugin's state persists across stages via the normal state-flow mechanism: values emitted in pre-process are available to read in publish.

## What the Request Gives You

`PluginRequest` provides everything your plugin needs at runtime:

| Property | What it is |
|----------|-----------|
| `hook` | Which pipeline stage is running (`preProcess`, `postProcess`, `publish`, `postPublish`) |
| `imageFolderPath` | Directory containing the images to process |
| `pluginConfig` | User-provided config values from the plugin's `config.json` |
| `secrets` | Sensitive values from the macOS Keychain (API keys, passwords) |
| `state` | Metadata state from all previous plugins in the pipeline |
| `skipped` | Images excluded from processing by upstream plugins (array of `{file, plugin}` records) |
| `dryRun` | Whether this is a preview run (skip destructive operations) |
| `dataPath` | Persistent storage directory for your plugin |
| `logPath` | Directory for plugin logs |
| `pluginVersion` | Your plugin's current version |
| `lastExecutedVersion` | Version from the previous run (useful for migrations) |

### Reading State from Other Plugins

State flows forward through the pipeline. If a pre-process plugin called `ghost-tagger` emitted a `ghost-tags` field, your publish plugin can read it:

```swift
let tags = request.state["ghost-tagger", "ghost-tags"]
```

For compile-time safety, define a `StateKey` enum:

```swift
enum GhostTaggerKeys: String, StateKey {
    static let namespace = "ghost-tagger"
    case ghostTags = "ghost-tags"
}

let tags = request.state[GhostTaggerKeys.ghostTags]
```

### Reporting Progress

Send live progress updates that piqley displays to the user:

```swift
request.reportProgress("Uploading photo 3 of 10...")
request.reportImageResult("sunset.jpg", success: true)
request.reportImageResult("blurry.jpg", success: false, error: "Upload failed: 413 Too Large")
```

## Secrets

Never hardcode API keys. Store them with piqley's secret management:

```bash
piqley secret set my-plugin admin-api-key
piqley secret set my-plugin api-url
```

Read them in your plugin:

```swift
guard let apiKey = request.secrets["admin-api-key"],
      let apiURL = request.secrets["api-url"] else {
    throw PluginError.missingSecret
}
```

## Declaring Your Plugin's Metadata

The SDK provides builder DSLs for generating your plugin's manifest, config, and stage files. These are typically called from a build script or setup tool, not from the plugin binary itself.

### Manifest

```swift
let manifest = try buildManifest {
    Identifier("com.example.ghost-publisher")
    Name("Ghost Publisher")
    Description("Schedules and publishes photos to Ghost CMS")
    ProtocolVersion("1.0")
    PluginVersion("1.0.0")

    ConfigEntries {
        Secret("admin-api-key", type: .string)
        Secret("api-url", type: .string)
        Value("scheduleWindowStart", type: .string, default: "08:00")
        Value("scheduleWindowEnd", type: .string, default: "20:00")
    }

    Dependencies {
        "ghost-tagger"
    }
}

try manifest.writeValidated(to: pluginDirectory)
```

### Stage Configuration

```swift
let stage = buildStage {
    PreRules {
        ConfigRule(
            match: .field(.keywords, pattern),
            emit: [.keywords(values)]
        )
    }

    Binary(
        command: "./bin/ghost-publisher",
        protocol: .jsonLines,
        timeout: 300
    )
}

try stage.write(to: pluginDirectory, hookName: "publish")
```

## Format Declarations

Plugins can declare which image formats they support and whether they convert images to a different format. These declarations go in the plugin manifest:

```swift
let manifest = try buildManifest {
    Identifier("com.example.resize")
    Name("Resize")
    // ...

    SupportedFormats(["JPEG", "PNG", "TIFF"])
    ConversionFormat("JPEG")
}
```

In the JSON manifest, these appear as top-level fields:

```json
{
  "identifier": "com.example.resize",
  "supportedFormats": ["JPEG", "PNG", "TIFF"],
  "conversionFormat": "JPEG"
}
```

The behavior depends on which fields are present:

| `supportedFormats` | `conversionFormat` | Behavior |
|---|---|---|
| absent | absent | Plugin accepts all formats, outputs unchanged |
| present | absent | Plugin only receives matching formats, outputs unchanged |
| absent | present | Plugin accepts all formats, converts output to the declared format |
| present | present | Plugin only receives matching formats, converts output to the declared format |

When `conversionFormat` is set, the orchestrator implicitly creates a fork for this plugin so the format conversion does not affect the main pipeline or other plugins.

## Fork/COW Pipeline

Forking creates a copy-on-write branch of the image data so a plugin can modify images without affecting the main pipeline. This is essential for plugins that resize, convert, or watermark images while other plugins need the original.

### Declaring a Fork

Set `fork: true` in a plugin's hook configuration:

```json
{
  "pipeline": {
    "pre-process": [
      { "plugin": "privacy-strip" },
      { "plugin": "resize", "fork": true }
    ]
  }
}
```

When `conversionFormat` is declared in the manifest, forking is implicit. You do not need to set `fork: true` separately.

### Fork Lifetime

A fork persists across all pipeline stages. If a plugin forks in pre-process, its fork is available in post-process, publish, and post-publish. Downstream plugins that declare a dependency on the forking plugin operate on that fork, not on main.

### Fork Source Resolution

When a plugin forks, it copies from its dependency's fork if one exists, otherwise from main. This creates a tree of forks:

- `resize` forks from main.
- `watermark` depends on `resize`, so it forks from the resize fork.
- `ghost-pre-process` depends on `watermark`, so it forks from the watermark fork.

Each fork is independent. Changes to the watermark fork do not affect the resize fork or main.

### writeBack

A plugin can merge its fork back to main using the `writeBack` post-rule action. This is useful when you want the main pipeline to receive the plugin's modified images (for example, writing watermarked images back so an archival plugin can pick them up):

```json
{
  "postRules": [
    { "action": "writeBack" }
  ]
}
```

writeBack replaces the main pipeline's image data with this fork's data. Only one plugin should writeBack per stage to avoid conflicts.

## Rule Negation

Rules support a `not` flag that inverts the match or action condition.

### Negating a Match

Add `"not": true` to the match block to fire the rule when the pattern does *not* match:

```json
{
  "match": { "field": "original:IPTC:Keywords", "pattern": "glob:Project 365", "not": true },
  "emit": [{ "field": "non-365", "values": ["true"] }]
}
```

This rule fires for every image that does not have a "Project 365" keyword.

### Negating remove/removeField (Allow-List Semantics)

Add `"not": true` to a `remove` or `removeField` action to invert it into an allow-list. Instead of removing the listed values, it removes everything *except* the listed values:

```json
{
  "write": [
    { "action": "removeField", "field": "EXIF:*", "not": true,
      "values": ["EXIF:DateTimeOriginal", "EXIF:ExposureTime", "EXIF:FNumber"] }
  ]
}
```

This removes all EXIF fields *except* DateTimeOriginal, ExposureTime, and FNumber. Without `not`, it would remove only those three fields.

## Clone Wildcard

The clone action supports `"field": "*"` to copy all fields from a source namespace at once:

```json
{
  "emit": [
    { "action": "clone", "field": "*", "source": "original" }
  ]
}
```

This clones every field from the `original` namespace into the current plugin's namespace. It is commonly combined with negated `removeField` to create an allow-list pattern: clone everything, then remove all except the fields you want to keep.

```json
{
  "emit": [
    { "action": "clone", "field": "*", "source": "original" },
    { "action": "removeField", "field": "IPTC:Keywords", "not": true }
  ]
}
```

This keeps only `IPTC:Keywords` from the original metadata, discarding everything else.

## Testing

The SDK provides a mock request for unit testing without running the full pipeline:

```swift
let (request, output) = PluginRequest.mock(
    hook: .publish,
    pluginConfig: ["scheduleWindowStart": .string("08:00")],
    secrets: ["admin-api-key": "test-key"]
)

let response = try await MyPlugin().handle(request)

// Inspect captured output
let progress = output.progressMessages   // ["Uploading photo 1 of 3...", ...]
let results = output.imageResults        // [ImageResult]
```

## Packaging and Distribution

Build your plugin into a distributable `.piqleyplugin` package:

```bash
swift build -c release
piqley-build
```

Users install it with:

```bash
piqley plugin install path/to/my-plugin.piqleyplugin
```

To update an already-installed plugin to a newer version:

```bash
piqley plugin update path/to/my-plugin.piqleyplugin
```

The update command replaces the plugin files but preserves existing config values and secrets. New config entries added by the updated manifest are prompted, and entries removed from the manifest are cleaned up automatically.

### Multi-Platform Plugins

Plugins can target multiple platforms by declaring platform-specific binaries in `piqley-build-manifest.json`. Supported platforms: `macos-arm64`, `linux-amd64`, `linux-arm64`.

```json
{
  "pluginSchemaVersion": "1",
  "bin": {
    "macos-arm64": [".build/release/my-plugin"],
    "linux-amd64": ["dist/my-plugin-amd64"],
    "linux-arm64": ["dist/my-plugin-arm64"]
  },
  "data": {
    "macos-arm64": ["models/mac-model.bin"],
    "linux-amd64": ["models/linux-model.bin"],
    "linux-arm64": ["models/linux-model.bin"]
  }
}
```

The packager bundles each platform's files into subdirectories inside the `.piqleyplugin` archive. When a user installs the plugin, piqley copies only the files for their platform and discards the rest. Interpreted plugins (Python, Node.js) use the same structure: provide a separate entry point per platform even if the scripts are identical, and factor shared logic into common files.

#### Building for Each Platform

**Swift**: Cross-compile using [Swift SDK bundles](https://www.swift.org/documentation/articles/static-linux-getting-started.html). From macOS you can produce Linux binaries. From Linux you can target a different Linux architecture.

Both `create-plugin.sh` and the generated `piqley-build.sh` handle SDK setup automatically: they detect your host platform, build natively for it, cross-compile for other targets using installed SDKs, and offer to install missing SDKs. If a platform can't be cross-compiled (e.g., macOS from Linux), the script warns and skips it. Use a macOS CI runner for that case.

**Go**: Use `GOOS`/`GOARCH` environment variables to cross-compile from any platform:

```bash
GOOS=darwin GOARCH=arm64 go build -o dist/macos-arm64/my-plugin
GOOS=linux GOARCH=amd64 go build -o dist/linux-amd64/my-plugin
GOOS=linux GOARCH=arm64 go build -o dist/linux-arm64/my-plugin
```

**Python/Node.js**: Scripts are typically portable. Use per-platform entry points only if you depend on platform-specific native modules.

See the [SDK README](https://github.com/josephquigley/piqley-plugin-sdk#multi-platform-support) for the full build workflow.

## Further Reading

- [Getting Started](getting-started.md) for piqley basics and CLI commands
- [Advanced Topics](advanced-topics.md) for declarative rule syntax, composability patterns, and real-world workflow examples
