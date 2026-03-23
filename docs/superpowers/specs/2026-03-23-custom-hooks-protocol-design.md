# Custom Hooks Protocol Design

## Problem

The `Hook` enum in PiqleyCore is a closed set of 6 built-in pipeline stages. Plugins cannot define custom hooks with type safety. Custom stages work via declarative JSON files, but the plugin binary has no compiler-enforced dispatch for them.

## Goal

Let plugins define custom hooks as enums with exhaustive switch dispatch, while keeping the wire format (JSON strings) unchanged. The CLI remains unaware of custom hook types.

## Design

### Hook Protocol (PiqleyCore)

The `Hook` enum becomes a protocol. Built-in hooks move to `StandardHook`.

```swift
public protocol Hook: RawRepresentable, CaseIterable, Codable, Sendable
    where RawValue == String {
    var stageConfig: StageConfig { get }
}

public enum StandardHook: String, Hook {
    case pipelineStart = "pipeline-start"
    case preProcess = "pre-process"
    case postProcess = "post-process"
    case publish = "publish"
    case postPublish = "post-publish"
    case pipelineFinished = "pipeline-finished"

    public static let canonicalOrder: [StandardHook] = [
        .pipelineStart, .preProcess, .postProcess,
        .publish, .postPublish, .pipelineFinished
    ]

    public var stageConfig: StageConfig {
        StageConfig(preRules: nil, binary: nil, postRules: nil)
    }
}
```

`Hook.defaultStageNames` and `Hook.canonicalOrder` move to `StandardHook`. All CLI references to the old `Hook` enum update to `StandardHook` where they reference the built-in stages.

### HookRegistry (PiqleyPluginSDK)

A registry that resolves hook strings to typed values and enumerates all registered hooks for stage file generation.

```swift
public final class HookRegistry: Sendable {
    private let boxes: [AnyHookBox]

    public init(_ registrations: (Registrar) -> Void) {
        let registrar = Registrar()
        registrations(registrar)
        self.boxes = registrar.boxes
    }

    public func resolve(_ rawValue: String) -> (any Hook)? {
        for box in boxes {
            if let hook = box.resolve(rawValue) {
                return hook
            }
        }
        return nil
    }

    public var allHooks: [any Hook] {
        boxes.flatMap { $0.allHooks }
    }

    public final class Registrar {
        fileprivate var boxes: [AnyHookBox] = []

        public func register<H: Hook>(_ type: H.Type) {
            boxes.append(AnyHookBox(type))
        }
    }
}
```

The type erasure box is internal to the SDK:

```swift
struct AnyHookBox: Sendable {
    private let _resolve: @Sendable (String) -> (any Hook)?
    private let _allHooks: @Sendable () -> [any Hook]

    init<H: Hook>(_ type: H.Type) {
        _resolve = { H(rawValue: $0) }
        _allHooks = { Array(H.allCases) }
    }

    func resolve(_ rawValue: String) -> (any Hook)? { _resolve(rawValue) }
    var allHooks: [any Hook] { _allHooks() }
}
```

### PluginRequest Changes (PiqleyPluginSDK)

`PluginRequest.hook` changes from the old `Hook` enum to `any Hook`. Resolution happens during init via the registry. No silent fallback: unrecognized hooks throw.

```swift
public struct PluginRequest: Sendable {
    public let hook: any Hook
    // all other fields unchanged
}

// init changes
init(payload: PluginInputPayload, io: PluginIO, registry: HookRegistry) throws {
    guard let hook = registry.resolve(payload.hook) else {
        throw HookResolutionError.unknownHook(payload.hook)
    }
    self.hook = hook
    // rest unchanged
}
```

### PiqleyPlugin Protocol Changes (PiqleyPluginSDK)

The protocol gains a `registry` property. The `run()` extension uses it for hook resolution and `--create-stage-files`.

```swift
public protocol PiqleyPlugin: Sendable {
    var registry: HookRegistry { get }
    func handle(_ request: PluginRequest) async throws -> PluginResponse
}
```

### --create-stage-files (PiqleyPluginSDK)

When the binary receives `--create-stage-files <output-dir>`, the SDK iterates all registered hooks and writes stage files:

```swift
// Inside run()
if CommandLine.arguments.contains("--create-stage-files") {
    let outputDir = URL(fileURLWithPath: CommandLine.arguments.last!)
    for hook in registry.allHooks {
        let config = hook.stageConfig
        guard !config.isEffectivelyEmpty else { continue }
        let filename = "\(PluginFile.stagePrefix)\(hook.rawValue)\(PluginFile.stageSuffix)"
        let data = try JSONEncoder().encode(config)
        try data.write(to: outputDir.appendingPathComponent(filename))
    }
    return
}
```

### Plugin-Side Dispatch Pattern

Plugins use type-casting switch for exhaustive dispatch within each hook enum:

```swift
func handle(_ request: PluginRequest) async throws -> PluginResponse {
    switch request.hook {
    case let h as StandardHook:
        switch h {
        case .pipelineStart: return .ok
        case .preProcess: return try await preProcess(request)
        case .postProcess: return try await postProcess(request)
        case .publish: return .ok
        case .postPublish: return .ok
        case .pipelineFinished: return .ok
        }
    default:
        throw HookResolutionError.unhandledHook(request.hook.rawValue)
    }
}
```

The `default` case is required by the compiler but unreachable if the registry matches what `handle()` covers.

### Custom Hook Example

A plugin defining custom watermark hooks:

```swift
enum WatermarkHook: String, Hook {
    case preWatermark = "pre-watermark"
    case postWatermark = "post-watermark"

    var stageConfig: StageConfig {
        switch self {
        case .preWatermark:
            return StageConfig(preRules: nil, binary: HookConfig(args: []), postRules: nil)
        case .postWatermark:
            return StageConfig(preRules: nil, binary: HookConfig(args: []), postRules: nil)
        }
    }
}

@main
struct Plugin: PiqleyPlugin {
    let registry = HookRegistry { r in
        r.register(StandardHook.self)
        r.register(WatermarkHook.self)
    }

    func handle(_ request: PluginRequest) async throws -> PluginResponse {
        switch request.hook {
        case let h as StandardHook:
            switch h { /* ... */ }
        case let h as WatermarkHook:
            switch h {
            case .preWatermark: return try await preWatermark(request)
            case .postWatermark: return try await postWatermark(request)
            }
        default:
            throw HookResolutionError.unhandledHook(request.hook.rawValue)
        }
    }
}
```

At build time, `--create-stage-files` produces `stage-pre-watermark.json` and `stage-post-watermark.json`. On install, the CLI discovers these and registers them as available in the `StageRegistry`. The user activates and positions them in `stages.json`.

## Changes by Repo

### PiqleyCore
- `Hook.swift`: enum becomes a protocol
- New `StandardHook.swift`: 6 built-in hooks as enum conforming to `Hook`
- `StageRegistry.swift`: references update from `Hook.defaultStageNames` to `StandardHook.canonicalOrder`
- `PluginInputPayload.hook` stays `String` (no change)

### PiqleyPluginSDK
- New `HookRegistry.swift`: public registry with `Registrar` builder
- New `AnyHookBox.swift`: internal type-erased box
- New `HookResolutionError.swift`: error type for unknown/unhandled hooks
- `PluginRequest.swift`: `hook` type changes to `any Hook`, init takes registry
- `Plugin.swift`: protocol gains `var registry: HookRegistry`, `run()` handles `--create-stage-files`
- Template update: uses registry and type-casting switch pattern

### PiqleyCLI
- References to old `Hook` enum update to `StandardHook` where applicable (stage registry seeding)
- No structural changes to `PluginDiscovery` or `PipelineOrchestrator`

## Wire Format

No changes. `PluginInputPayload.hook` remains a `String`. The JSON schemas are unchanged.

## Template Changes

Swift template pre-registers `StandardHook` for convenience. Go and Python templates are unaffected since they already work with hook strings directly.
