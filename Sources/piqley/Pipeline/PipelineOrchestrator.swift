import Foundation
import Logging
import PiqleyCore

struct PipelineOrchestrator: Sendable {
    let workflow: Workflow
    let pluginsDirectory: URL
    let secretStore: any SecretStore
    let registry: StageRegistry
    let workflowsRoot: URL?
    let versionStateStore: any VersionStateStore
    let logger = Logger(label: "piqley.pipeline")

    init(
        workflow: Workflow,
        pluginsDirectory: URL,
        secretStore: any SecretStore,
        registry: StageRegistry,
        workflowsRoot: URL? = nil,
        versionStateStore: any VersionStateStore = FileVersionStateStore(
            pluginsDirectory: defaultPluginsDirectory
        )
    ) {
        self.workflow = workflow
        self.pluginsDirectory = pluginsDirectory
        self.secretStore = secretStore
        self.registry = registry
        self.workflowsRoot = workflowsRoot
        self.versionStateStore = versionStateStore
    }

    /// Resolves the default plugins directory.
    static var defaultPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.plugins)
    }

    /// Runs the full pipeline for a source folder.
    /// Returns `true` if all hooks succeeded, `false` if any hook aborted the pipeline.
    func run(sourceURL: URL, dryRun: Bool, debug: Bool, nonInteractive: Bool = false, overwriteSource: Bool = false) async throws -> Bool {
        let pipeline = workflow.pipeline
        let pipelineRunId = UUID().uuidString

        // Create temp folder and copy images
        let temp = try TempFolder.create()
        logger.info("Temp folder: \(temp.url.path)")
        let copyResult: TempFolder.CopyResult
        do {
            copyResult = try temp.copyImages(from: sourceURL)
        } catch {
            try? temp.delete()
            throw error
        }
        for skipped in copyResult.skippedFiles {
            logger.warning("Skipping '\(skipped)': unsupported format")
        }
        if copyResult.copiedCount == 0 {
            logger.error("No supported image files found in \(sourceURL.path)")
            try? temp.delete()
            return false
        }

        let blocklist = PluginBlocklist()
        let stateStore = StateStore()
        var ruleEvaluatorCache: [String: RuleEvaluator] = [:]

        // Extract metadata from all images into original namespace
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: temp.url, includingPropertiesForKeys: nil
        ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

        for imageFile in imageFiles {
            let metadata = MetadataExtractor.extract(from: imageFile)
            await stateStore.setNamespace(
                image: imageFile.lastPathComponent,
                plugin: ReservedName.original,
                values: metadata
            )
        }

        // Validate plugin dependencies
        do {
            try validateDependencies(pipeline: pipeline)
        } catch is PipelineError {
            try? temp.delete()
            return false
        }

        // Validate all binaries before starting
        do {
            try validateBinaries(pipeline: pipeline)
        } catch is PipelineError {
            try? temp.delete()
            return false
        }

        defer {
            do {
                try temp.delete()
                logger.debug("Temp folder deleted")
            } catch {
                logger.warning("Failed to delete temp folder: \(error)")
            }
        }

        // Execute hooks in order from registry
        logger.info("Pipeline run \(pipelineRunId) starting")
        var skippedImages: Set<String> = []
        var executedPlugins: [(hook: String, pluginId: String)] = []
        var pipelineFailed = false

        for stage in registry.executionOrder {
            guard !pipelineFailed else { break }

            for pluginEntry in pipeline[stage] ?? [] {
                guard !pipelineFailed else { break }
                guard !blocklist.isBlocked(pluginEntry) else {
                    logger.debug("[\(pluginEntry)] skipped (blocklisted)")
                    continue
                }

                let resolvedHook = registry.resolvedHook(for: stage)
                let ctx = HookContext(
                    pluginIdentifier: pluginEntry, pluginName: pluginEntry,
                    hook: resolvedHook, stage: stage, temp: temp,
                    stateStore: stateStore, imageFiles: imageFiles,
                    dryRun: dryRun, debug: debug, nonInteractive: nonInteractive,
                    skippedImages: skippedImages,
                    executedPlugins: executedPlugins,
                    pipelineRunId: pipelineRunId
                )
                let (result, updatedSkipped) = try await runPluginHook(ctx, ruleEvaluatorCache: &ruleEvaluatorCache)
                skippedImages = updatedSkipped

                switch result {
                case .success, .warning, .skipped:
                    executedPlugins.append((hook: stage, pluginId: pluginEntry))
                case .pluginNotFound, .secretMissing, .ruleCompilationFailed, .critical:
                    blocklist.block(pluginEntry)
                    pipelineFailed = true
                }
            }
        }

        logger.info("Pipeline run \(pipelineRunId) finished")

        if pipelineFailed {
            return false
        }

        // Copy processed images back to source if requested
        if overwriteSource {
            try temp.copyBack(to: sourceURL)
            logger.info("Copied processed images back to \(sourceURL.path)")
        }

        return true
    }

    // MARK: - Types

    struct HookContext {
        let pluginIdentifier: String
        let pluginName: String
        let hook: String
        let stage: String
        let temp: TempFolder
        let stateStore: StateStore
        let imageFiles: [URL]
        let dryRun: Bool
        let debug: Bool
        let nonInteractive: Bool
        let skippedImages: Set<String>
        let executedPlugins: [(hook: String, pluginId: String)]
        let pipelineRunId: String
    }

    enum HookResult {
        case success, warning, critical, skipped
        case pluginNotFound, secretMissing, ruleCompilationFailed
    }

    struct RulesetResult {
        let didRun: Bool
        let skippedImages: Set<String>
    }

    // MARK: - Per-Plugin Hook Execution

    private func runPluginHook(
        _ ctx: HookContext,
        ruleEvaluatorCache: inout [String: RuleEvaluator]
    ) async throws -> (HookResult, Set<String>) {
        var skippedImages = ctx.skippedImages

        guard let loadedPlugin = try loadPlugin(named: ctx.pluginIdentifier) else {
            logger.error("Plugin '\(ctx.pluginIdentifier)' not found in \(pluginsDirectory.path)")
            return (.pluginNotFound, skippedImages)
        }

        guard let stageConfig = loadedPlugin.stages[ctx.stage] else {
            logger.debug("[\(loadedPlugin.name)] stage '\(ctx.stage)': no stage file -- skipping")
            return (.skipped, skippedImages)
        }

        let configResult = resolvePluginConfigAndSecrets(
            plugin: loadedPlugin, pluginIdentifier: ctx.pluginIdentifier
        )
        let secrets: [String: String]
        let pluginConfig: PluginConfig
        switch configResult {
        case let .resolved(sec, conf):
            secrets = sec
            pluginConfig = conf
        case .secretMissing:
            return (.secretMissing, skippedImages)
        }

        let execLogPath = pluginsDirectory
            .appendingPathComponent(ctx.pluginIdentifier)
            .appendingPathComponent(PluginFile.executionLog)
        try FileManager.default.createDirectory(
            at: execLogPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let manifestDeps = loadedPlugin.manifest.dependencyIdentifiers

        let currentImageFiles = try FileManager.default.contentsOfDirectory(
            at: ctx.temp.url, includingPropertiesForKeys: nil
        ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

        let imageURLs = Dictionary(uniqueKeysWithValues: currentImageFiles.map {
            ($0.lastPathComponent, $0)
        })
        let buffer = MetadataBuffer(imageURLs: imageURLs)

        logger.info("Running plugin '\(loadedPlugin.name)' for stage '\(ctx.stage)'")

        // Pre-rules
        var preRulesDidRun = false
        if let preRules = stageConfig.preRules, !preRules.isEmpty {
            do {
                let rulesetResult = try await evaluateRuleset(
                    rules: preRules, ctx: ctx, manifestDeps: manifestDeps,
                    buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
                    cacheKey: "\(ctx.pluginIdentifier):pre:\(ctx.stage)",
                    skippedImages: skippedImages
                )
                preRulesDidRun = rulesetResult.didRun
                skippedImages = rulesetResult.skippedImages
            } catch {
                logger.error("[\(loadedPlugin.name)] pre-rule compilation failed: \(error.localizedDescription)")
                return (.ruleCompilationFailed, skippedImages)
            }
        }

        await buffer.flush()

        // Remove skipped images from the image folder so the binary never sees them
        for imageName in skippedImages {
            let imageURL = ctx.temp.url.appendingPathComponent(imageName)
            try? FileManager.default.removeItem(at: imageURL)
        }

        // Binary
        var binaryDidRun = false
        if let binaryCommand = stageConfig.binary?.command, binaryCommand.isEmpty {
            logger.warning("[\(loadedPlugin.name)] stage '\(ctx.stage)': binary command is empty, skipping binary")
        }
        if let binaryCommand = stageConfig.binary?.command, !binaryCommand.isEmpty {
            // Skip binary entirely if all images are skipped
            let allImageNames = Set(currentImageFiles.map(\.lastPathComponent))
            if allImageNames.isSubset(of: skippedImages) {
                logger.info("[\(loadedPlugin.name)] stage '\(ctx.stage)': all images skipped, skipping binary")
            } else {
                let skipRecords = await buildSkipRecords(skippedImages: skippedImages, stateStore: ctx.stateStore)

                let (result, runtimeSkips) = try await runBinary(
                    ctx, loadedPlugin: loadedPlugin,
                    secrets: secrets, pluginConfig: pluginConfig,
                    hookConfig: stageConfig.binary, manifestDeps: manifestDeps,
                    rulesDidRun: preRulesDidRun, execLogPath: execLogPath,
                    skipped: skipRecords,
                    skippedImages: skippedImages,
                    metadataBuffer: buffer,
                    pipelineRunId: ctx.pipelineRunId
                )
                skippedImages.formUnion(runtimeSkips)
                switch result {
                case .success, .warning:
                    binaryDidRun = true
                case .critical, .pluginNotFound, .secretMissing, .ruleCompilationFailed:
                    return (result, skippedImages)
                case .skipped:
                    break
                }
            }
        }

        // Invalidate cache after binary
        if binaryDidRun {
            await buffer.invalidateAll()
        }

        // Post-rules
        if let postRules = stageConfig.postRules, !postRules.isEmpty {
            do {
                let rulesetResult = try await evaluateRuleset(
                    rules: postRules, ctx: ctx, manifestDeps: manifestDeps,
                    buffer: buffer, ruleEvaluatorCache: &ruleEvaluatorCache,
                    cacheKey: "\(ctx.pluginIdentifier):post:\(ctx.stage)",
                    skippedImages: skippedImages
                )
                skippedImages = rulesetResult.skippedImages
            } catch {
                logger.error("[\(loadedPlugin.name)] post-rule compilation failed: \(error.localizedDescription)")
                return (.ruleCompilationFailed, skippedImages)
            }
        }

        await buffer.flush()

        if !preRulesDidRun, !binaryDidRun, (stageConfig.postRules ?? []).isEmpty {
            return (.skipped, skippedImages)
        }

        // Persist version after successful pipeline-start
        if ctx.stage == StandardHook.pipelineStart.rawValue {
            let pluginVersion = loadedPlugin.manifest.pluginVersion
                ?? SemanticVersion(major: 0, minor: 0, patch: 0)
            do {
                try versionStateStore.save(version: pluginVersion, for: ctx.pluginIdentifier)
            } catch {
                logger.warning(
                    "[\(loadedPlugin.name)] failed to save version state: \(error)"
                )
            }
        }

        return (.success, skippedImages)
    }
}
