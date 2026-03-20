# Plugin Development with the SDK

When declarative rules aren't enough (you need API calls, image manipulation, or complex logic), build a binary plugin. The [piqley plugin SDK](https://github.com/josephquigley/piqley-plugin-sdk) handles all the communication with piqley so you can focus on your plugin's logic.

This guide covers the Swift SDK. Python, Node.js, and Go SDKs follow the same concepts.

## Scaffold a Project

```bash
piqley plugin create ~/Developer/my-plugin --language swift
```

This generates a ready-to-build Swift package with the SDK dependency wired up.

## The Plugin Protocol

A plugin is a single async function:

```swift
@main
struct MyPlugin: PiqleyPlugin {
    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        let images = try request.imageFiles()

        for image in images {
            request.reportProgress("Processing \(image.lastPathComponent)...")

            // Your logic here

            request.reportImageResult(image.lastPathComponent, success: true)
        }

        return .ok
    }

    static func main() async {
        await MyPlugin().run()
    }
}
```

Call `run()` from your entry point. The SDK reads the request from stdin, calls your `handle` method, and writes the response to stdout. You never deal with JSON parsing or the communication protocol directly.

## What the Request Gives You

`PluginRequest` provides everything your plugin needs at runtime:

| Property | What it is |
|----------|-----------|
| `hook` | Which pipeline stage is running (`preProcess`, `postProcess`, `publish`, `postPublish`) |
| `imageFolderPath` | Directory containing the images to process |
| `pluginConfig` | User-provided config values from the plugin's `config.json` |
| `secrets` | Sensitive values from the macOS Keychain (API keys, passwords) |
| `state` | Metadata state from all previous plugins in the pipeline |
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

## Further Reading

- [Getting Started](getting-started.md) for piqley basics and CLI commands
- [Advanced Topics](advanced-topics.md) for declarative rule syntax, composability patterns, and real-world workflow examples
