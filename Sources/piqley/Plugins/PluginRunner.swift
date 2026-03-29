import Foundation
import Logging
import PiqleyCore

/// Runs a single plugin hook as a subprocess.
struct PluginRunner: Sendable {
    let plugin: LoadedPlugin
    let secrets: [String: String]
    let pluginConfig: PluginConfig
    let metadataBuffer: MetadataBuffer?
    let logger = Logger(label: "piqley.runner")

    init(plugin: LoadedPlugin, secrets: [String: String], pluginConfig: PluginConfig, metadataBuffer: MetadataBuffer? = nil) {
        self.plugin = plugin
        self.secrets = secrets
        self.pluginConfig = pluginConfig
        self.metadataBuffer = metadataBuffer
    }

    static let defaultTimeoutSeconds = 30

    /// Result of running a plugin hook.
    struct RunOutput {
        let exitResult: ExitCodeResult
        let state: [String: [String: JSONValue]]?
        let errorMessage: String?
        let skippedImages: [String]
    }

    // Runs the plugin for a given hook. Returns the exit code result, any state
    // returned by the plugin (JSON protocol only, nil for pipe/batchProxy),
    // and an optional error message from the plugin's result line.
    // swiftlint:disable:next function_parameter_count
    func run(
        hook: String,
        hookConfig: HookConfig?,
        tempFolder: TempFolder,
        executionLogPath: URL,
        dryRun: Bool,
        debug: Bool,
        state: [String: [String: [String: JSONValue]]]? = nil,
        skipped: [SkipRecord] = [],
        imageFolderOverride: URL? = nil,
        pipelineRunId: String? = nil
    ) async throws -> RunOutput {
        guard let hookConfig else {
            logger.error("Plugin '\(plugin.identifier)' has no hook config for hook '\(hook)'")
            return RunOutput(exitResult: .critical, state: nil, errorMessage: nil, skippedImages: [])
        }

        guard let command = hookConfig.command else {
            logger.error("Plugin '\(plugin.identifier)' hook '\(hook)': no command specified")
            return RunOutput(exitResult: .critical, state: nil, errorMessage: nil, skippedImages: [])
        }

        let proto = hookConfig.pluginProtocol ?? .json
        let effectiveFolderURL = imageFolderOverride ?? tempFolder.url

        if proto == .json, hookConfig.batchProxy != nil {
            logger.error("Plugin '\(plugin.identifier)' hook '\(hook)': batchProxy is only valid with pipe protocol")
            return RunOutput(exitResult: .critical, state: nil, errorMessage: nil, skippedImages: [])
        }

        if proto == .pipe, let batchProxy = hookConfig.batchProxy {
            let result = try await runBatchProxy(context: BatchRunContext(
                hook: hook,
                hookConfig: hookConfig,
                batchProxy: batchProxy,
                tempFolder: tempFolder,
                executionLogPath: executionLogPath,
                dryRun: dryRun,
                debug: debug,
                state: state,
                imageFolderOverride: imageFolderOverride,
                pipelineRunId: pipelineRunId
            ))
            return RunOutput(exitResult: result, state: nil, errorMessage: nil, skippedImages: [])
        }

        var environment = buildEnvironment(
            hook: hook,
            folderPath: effectiveFolderURL,
            imagePath: nil,
            executionLogPath: executionLogPath,
            dryRun: dryRun,
            debug: debug,
            pipelineRunId: pipelineRunId
        )
        // Resolve environment mapping templates against state for the first image
        // (JSON protocol has full state on stdin; pipe has no per-image context)
        let firstImageEntry = state?.first
        await resolveEnvironmentMapping(
            hookConfig: hookConfig, imageState: firstImageEntry?.value,
            imageName: firstImageEntry?.key, into: &environment
        )
        let args = substitute(args: hookConfig.args, environment: environment)
        let executable = resolveExecutable(command)

        switch proto {
        case .json:
            return try await runJSON(context: JSONRunContext(
                hook: hook,
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig,
                folderPath: effectiveFolderURL,
                executionLogPath: executionLogPath,
                dryRun: dryRun,
                debug: debug,
                state: state,
                skipped: skipped,
                pipelineRunId: pipelineRunId
            ))
        case .pipe:
            let result = try await runPipe(
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig
            )
            return RunOutput(exitResult: result, state: nil, errorMessage: nil, skippedImages: [])
        }
    }

    // MARK: - JSON Protocol

    /// Encapsulates the inputs required for a single json-protocol hook invocation.
    private struct JSONRunContext {
        let hook: String
        let executable: String
        let args: [String]
        let environment: [String: String]
        let hookConfig: HookConfig
        let folderPath: URL
        let executionLogPath: URL
        let dryRun: Bool
        let debug: Bool
        let state: [String: [String: [String: JSONValue]]]?
        let skipped: [SkipRecord]
        let pipelineRunId: String?
    }

    private func runJSON(
        context: JSONRunContext
    ) async throws -> RunOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: context.executable)
        process.arguments = context.args
        process.environment = context.environment
        process.currentDirectoryURL = plugin.directory.appendingPathComponent(PluginDirectory.data)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write JSON payload to stdin
        let payload = buildJSONPayload(
            hook: context.hook,
            folderPath: context.folderPath,
            executionLogPath: context.executionLogPath,
            dryRun: context.dryRun,
            debug: context.debug,
            state: context.state,
            skipped: context.skipped,
            pipelineRunId: context.pipelineRunId
        )
        if let data = try? JSONEncoder.piqley.encode(payload) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timeoutSeconds = context.hookConfig.timeout ?? Self.defaultTimeoutSeconds
        return await readJSONOutput(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            hookConfig: context.hookConfig,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func readJSONOutput(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        hookConfig: HookConfig,
        timeoutSeconds: Int
    ) async -> RunOutput {
        let evaluator = hookConfig.makeEvaluator()
        let activityTracker = ActivityTracker()
        var gotResult = false
        var resultState: [String: [String: JSONValue]]?
        var resultError: String?
        var skippedFilenames: [String] = []

        // Background task reads stderr and updates activity
        let stderrTask = Task {
            let handle = stderrPipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                await activityTracker.touch()
                logger.debug("[\(plugin.name)] stderr: \(line)")
            }
        }

        // Timeout watchdog
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let elapsed = await activityTracker.secondsSinceLastActivity()
                if elapsed > Double(timeoutSeconds) {
                    process.terminate()
                    return
                }
            }
        }

        // Read stdout lines
        do {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                await activityTracker.touch()
                guard let data = line.data(using: .utf8) else { continue }
                guard let obj = try? JSONDecoder.piqley.decode(PluginOutputLine.self, from: data) else {
                    // Non-JSON line — log and skip (plugin may emit debug output before result)
                    logger.debug("[\(plugin.name)]: non-JSON stdout line — skipping: \(line)")
                    continue
                }
                switch obj.type {
                case "progress":
                    logger.info("[\(plugin.name)]: \(obj.message ?? "")")
                case "imageResult":
                    logger.debug(
                        "[\(plugin.name)] imageResult: \(obj.filename ?? "") status=\(obj.status?.rawValue ?? "unknown")"
                    )
                    if obj.status == .skip, let filename = obj.filename {
                        skippedFilenames.append(filename)
                    }
                case "result":
                    gotResult = true
                    resultState = obj.state
                    resultError = obj.error
                default:
                    break
                }
            }
        } catch {
            logger.warning("[\(plugin.name)]: error reading stdout: \(error)")
        }

        watchdog.cancel()
        stderrTask.cancel()
        process.waitUntilExit()

        if !gotResult {
            logger.warning("[\(plugin.name)]: no 'result' line received — treating as critical")
            return RunOutput(exitResult: .critical, state: nil, errorMessage: nil, skippedImages: [])
        }

        return RunOutput(
            exitResult: evaluator.evaluate(process.terminationStatus),
            state: resultState,
            errorMessage: resultError,
            skippedImages: skippedFilenames
        )
    }

    // MARK: - Pipe Protocol

    private func runPipe(
        executable: String,
        args: [String],
        environment: [String: String],
        hookConfig: HookConfig
    ) async throws -> ExitCodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = plugin.directory.appendingPathComponent(PluginDirectory.data)
        // stdout/stderr forwarded to our stdout/stderr
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()

        let timeoutSeconds = hookConfig.timeout ?? Self.defaultTimeoutSeconds
        // Known limitation: pipe protocol uses a wall-clock timeout (not inactivity-based)
        // because stdout goes directly to the terminal and can't be intercepted without
        // buffering. A pipe plugin that emits output will still be killed after `timeoutSeconds`
        // of wall-clock time. This is a deliberate trade-off for protocol simplicity.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                logger.warning("[\(plugin.name)]: inactivity timeout — killing process")
                process.terminate()
            }
        }
        process.waitUntilExit()
        watchdog.cancel()

        return hookConfig.makeEvaluator().evaluate(process.terminationStatus)
    }

    // MARK: - BatchProxy

    /// Encapsulates the inputs required for a batch-proxy hook invocation.
    private struct BatchRunContext {
        let hook: String
        let hookConfig: HookConfig
        let batchProxy: BatchProxyConfig
        let tempFolder: TempFolder
        let executionLogPath: URL
        let dryRun: Bool
        let debug: Bool
        let state: [String: [String: [String: JSONValue]]]?
        let imageFolderOverride: URL?
        let pipelineRunId: String?
    }

    private func runBatchProxy(context: BatchRunContext) async throws -> ExitCodeResult {
        let effectiveFolder = context.imageFolderOverride ?? context.tempFolder.url
        let images = try sortedImages(in: effectiveFolder, sort: context.batchProxy.sort)

        for image in images {
            var environment = buildEnvironment(
                hook: context.hook,
                folderPath: effectiveFolder,
                imagePath: image,
                executionLogPath: context.executionLogPath,
                dryRun: context.dryRun,
                debug: context.debug,
                pipelineRunId: context.pipelineRunId
            )
            let imageName = image.lastPathComponent
            let imageState = context.state?[imageName]
            await resolveEnvironmentMapping(
                hookConfig: context.hookConfig, imageState: imageState,
                imageName: imageName, into: &environment
            )
            let args = substitute(args: context.hookConfig.args, environment: environment)
            let executable = resolveExecutable(context.hookConfig.command!)
            let result = try await runPipe(
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: context.hookConfig
            )
            if result == .critical { return .critical }
        }
        return .success
    }

    // MARK: - Helpers

    private func resolveExecutable(_ command: String) -> String {
        if command.hasPrefix("/") { return command }
        // Relative path — resolve against plugin directory
        return plugin.directory.appendingPathComponent(command).path
    }

    private func substitute(args: [String], environment: [String: String]) -> [String] {
        args.map { arg in
            var result = arg
            for (key, value) in environment {
                result = result.replacingOccurrences(of: "$\(key)", with: value)
            }
            return result
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func buildEnvironment(
        hook: String,
        folderPath: URL,
        imagePath: URL?,
        executionLogPath: URL,
        dryRun: Bool,
        debug: Bool,
        pipelineRunId: String? = nil
    ) -> [String: String] {
        var env: [String: String] = [
            PluginEnvironment.folderPath: folderPath.path,
            PluginEnvironment.hook: hook,
            PluginEnvironment.dryRun: dryRun ? "1" : "0",
            PluginEnvironment.debug: debug ? "1" : "0",
            PluginEnvironment.execLogPath: executionLogPath.path,
        ]
        if let imagePath {
            env[PluginEnvironment.imagePath] = imagePath.path
        }
        if let pipelineRunId {
            env[PluginEnvironment.pipelineRunId] = pipelineRunId
        }
        for (key, value) in secrets {
            env[PluginEnvironment.secretPrefix + key.uppercased().replacingOccurrences(of: "-", with: "_")] = value
        }
        for (key, value) in pluginConfig.values {
            let envKey = PluginEnvironment.configPrefix + key.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envKey] = jsonValueToString(value)
        }
        return env
    }

    private func buildJSONPayload(
        hook: String,
        folderPath: URL,
        executionLogPath: URL,
        dryRun: Bool,
        debug: Bool,
        state: [String: [String: [String: JSONValue]]]? = nil,
        skipped: [SkipRecord] = [],
        pipelineRunId: String? = nil
    ) -> PluginInputPayload {
        let dataPath = plugin.directory.appendingPathComponent(PluginDirectory.data).path
        let logPath = plugin.directory.appendingPathComponent(PluginDirectory.logs).path
        let pluginVersion = plugin.manifest.pluginVersion ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        return PluginInputPayload(
            hook: hook,
            imageFolderPath: folderPath.path,
            pluginConfig: pluginConfig.values,
            secrets: secrets,
            executionLogPath: executionLogPath.path,
            dataPath: dataPath,
            logPath: logPath,
            dryRun: dryRun,
            debug: debug,
            state: state,
            pluginVersion: pluginVersion,
            lastExecutedVersion: nil,
            skipped: skipped,
            pipelineRunId: pipelineRunId
        )
    }

    private func sortedImages(
        in directory: URL,
        sort: SortConfig?
    ) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { TempFolder.imageExtensions.contains($0.pathExtension.lowercased()) }

        guard let sort else { return contents }

        switch sort.key {
        case "filename":
            let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return sort.order == .ascending ? sorted : sorted.reversed()
        default:
            // EXIF/IPTC sort keys require metadata reading — return filename-sorted as fallback
            logger.warning(
                "batchProxy sort key '\(sort.key)' requires metadata reading — falling back to filename sort"
            )
            return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
}

// MARK: - Concurrency Helpers

/// Tracks the timestamp of last activity for inactivity-based timeouts.
private actor ActivityTracker {
    private var lastActivity: Date = .init()

    func touch() {
        lastActivity = Date()
    }

    func secondsSinceLastActivity() -> Double {
        Date().timeIntervalSince(lastActivity)
    }
}
