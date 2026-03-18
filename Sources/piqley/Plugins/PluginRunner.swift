import Foundation
import Logging

/// Runs a single plugin hook as a subprocess.
struct PluginRunner: Sendable {
    let plugin: LoadedPlugin
    let secrets: [String: String]
    let pluginConfig: PluginConfig
    private let logger = Logger(label: "piqley.runner")

    static let defaultTimeoutSeconds = 30

    func run(
        hook: String,
        tempFolder: TempFolder,
        executionLogPath: URL,
        dryRun: Bool
    ) async throws -> ExitCodeResult {
        guard let hookConfig = plugin.manifest.hooks[hook] else {
            logger.error("Plugin '\(plugin.name)' has no config for hook '\(hook)'")
            return .critical
        }

        let proto = hookConfig.pluginProtocol ?? .json

        if proto == .json, hookConfig.batchProxy != nil {
            logger.error("Plugin '\(plugin.name)' hook '\(hook)': batchProxy is only valid with pipe protocol")
            return .critical
        }

        if proto == .pipe, let batchProxy = hookConfig.batchProxy {
            return try await runBatchProxy(context: BatchRunContext(
                hook: hook,
                hookConfig: hookConfig,
                batchProxy: batchProxy,
                tempFolder: tempFolder,
                executionLogPath: executionLogPath,
                dryRun: dryRun
            ))
        }

        let environment = buildEnvironment(
            hook: hook,
            folderPath: tempFolder.url,
            imagePath: nil,
            executionLogPath: executionLogPath,
            dryRun: dryRun
        )
        let args = substitute(args: hookConfig.args, environment: environment)
        let executable = resolveExecutable(hookConfig.command)

        switch proto {
        case .json:
            return try await runJSON(context: JSONRunContext(
                hook: hook,
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig,
                folderPath: tempFolder.url,
                executionLogPath: executionLogPath,
                dryRun: dryRun
            ))
        case .pipe:
            return try await runPipe(
                executable: executable,
                args: args,
                environment: environment,
                hookConfig: hookConfig
            )
        }
    }

    // MARK: - JSON Protocol

    /// Encapsulates the inputs required for a single json-protocol hook invocation.
    private struct JSONRunContext {
        let hook: String
        let executable: String
        let args: [String]
        let environment: [String: String]
        let hookConfig: PluginManifest.HookConfig
        let folderPath: URL
        let executionLogPath: URL
        let dryRun: Bool
    }

    private func runJSON(context: JSONRunContext) async throws -> ExitCodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: context.executable)
        process.arguments = context.args
        process.environment = context.environment
        process.currentDirectoryURL = plugin.directory.appendingPathComponent("data")

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
            dryRun: context.dryRun
        )
        if let data = try? JSONEncoder().encode(payload) {
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
        hookConfig: PluginManifest.HookConfig,
        timeoutSeconds: Int
    ) async -> ExitCodeResult {
        let evaluator = hookConfig.makeEvaluator()
        let activityTracker = ActivityTracker()
        var gotResult = false

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
                guard let obj = try? JSONDecoder().decode(PluginOutputLine.self, from: data) else {
                    // Non-JSON line — log and skip (plugin may emit debug output before result)
                    logger.debug("[\(plugin.name)]: non-JSON stdout line — skipping: \(line)")
                    continue
                }
                switch obj.type {
                case "progress":
                    logger.info("[\(plugin.name)]: \(obj.message ?? "")")
                case "imageResult":
                    logger.debug("[\(plugin.name)] imageResult: \(obj.filename ?? "") success=\(obj.success ?? false)")
                case "result":
                    gotResult = true
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
            return .critical
        }

        return evaluator.evaluate(process.terminationStatus)
    }

    // MARK: - Pipe Protocol

    private func runPipe(
        executable: String,
        args: [String],
        environment: [String: String],
        hookConfig: PluginManifest.HookConfig
    ) async throws -> ExitCodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = plugin.directory.appendingPathComponent("data")
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
        let hookConfig: PluginManifest.HookConfig
        let batchProxy: PluginManifest.BatchProxyConfig
        let tempFolder: TempFolder
        let executionLogPath: URL
        let dryRun: Bool
    }

    private func runBatchProxy(context: BatchRunContext) async throws -> ExitCodeResult {
        let images = try sortedImages(in: context.tempFolder.url, sort: context.batchProxy.sort)

        for image in images {
            let environment = buildEnvironment(
                hook: context.hook,
                folderPath: context.tempFolder.url,
                imagePath: image,
                executionLogPath: context.executionLogPath,
                dryRun: context.dryRun
            )
            let args = substitute(args: context.hookConfig.args, environment: environment)
            let executable = resolveExecutable(context.hookConfig.command)
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

    private func buildEnvironment(
        hook: String,
        folderPath: URL,
        imagePath: URL?,
        executionLogPath: URL,
        dryRun: Bool
    ) -> [String: String] {
        var env: [String: String] = [
            "PIQLEY_FOLDER_PATH": folderPath.path,
            "PIQLEY_HOOK": hook,
            "PIQLEY_DRY_RUN": dryRun ? "1" : "0",
            "PIQLEY_EXECUTION_LOG_PATH": executionLogPath.path,
        ]
        if let imagePath {
            env["PIQLEY_IMAGE_PATH"] = imagePath.path
        }
        for (key, value) in secrets {
            env["PIQLEY_SECRET_\(key.uppercased().replacingOccurrences(of: "-", with: "_"))"] = value
        }
        for (key, value) in pluginConfig.values {
            let envKey = "PIQLEY_CONFIG_" + key.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envKey] = jsonValueToString(value)
        }
        return env
    }

    private func jsonValueToString(_ value: JSONValue) -> String {
        switch value {
        case let .string(str): str
        case let .number(num):
            if num.truncatingRemainder(dividingBy: 1) == 0 {
                String(Int(num))
            } else {
                String(num)
            }
        case let .bool(flag): String(flag)
        default: ""
        }
    }

    private func buildJSONPayload(
        hook: String,
        folderPath: URL,
        executionLogPath: URL,
        dryRun: Bool
    ) -> PluginInputPayload {
        PluginInputPayload(
            hook: hook,
            folderPath: folderPath.path,
            pluginConfig: pluginConfig.values,
            secrets: secrets,
            executionLogPath: executionLogPath.path,
            dryRun: dryRun
        )
    }

    private func sortedImages(
        in directory: URL,
        sort: PluginManifest.SortConfig?
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
            logger.warning("batchProxy sort key '\(sort.key)' requires metadata reading — falling back to filename sort")
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

// MARK: - JSON I/O Types

private struct PluginInputPayload: Encodable {
    let hook: String
    let folderPath: String
    let pluginConfig: [String: JSONValue]
    let secrets: [String: String]
    let executionLogPath: String
    let dryRun: Bool
}

private struct PluginOutputLine: Decodable {
    let type: String
    let message: String?
    let filename: String?
    let success: Bool?
    let error: String?
}
