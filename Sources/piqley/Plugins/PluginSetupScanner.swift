import Foundation
import Logging
import PiqleyCore

/// Abstraction for reading user input. Uses `mutating` so both a mock
/// (which advances an index) and the real stdin (non-mutating) can conform.
protocol InputSource {
    mutating func readLine() -> String?
}

/// Reads from standard input.
struct StdinInputSource: InputSource {
    func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }
}

struct PluginSetupScanner {
    let secretStore: any SecretStore
    var inputSource: any InputSource
    private let logger = Logger(label: "piqley.setup-scanner")

    /// Runs setup scan for a single plugin.
    mutating func scan(plugin: LoadedPlugin, force: Bool = false) throws {
        let configURL = plugin.directory.appendingPathComponent(PluginFile.config)
        var pluginConfig = force ? PluginConfig() : PluginConfig.load(fromIfExists: configURL)

        // Phase 1: Config value resolution
        for entry in plugin.manifest.config {
            guard case let .value(key, type, defaultValue) = entry else { continue }
            if !force, pluginConfig.values[key] != nil { continue }
            let resolved = promptForValue(pluginName: plugin.name, key: key, type: type, defaultValue: defaultValue)
            pluginConfig = pluginConfig.settingValue(resolved, forKey: key)
        }

        // Phase 2: Secret validation
        let hasSecrets = plugin.manifest.config.contains {
            if case .secret = $0 { true } else { false }
        }
        for entry in plugin.manifest.config {
            guard case let .secret(secretKey, _) = entry else { continue }
            do {
                _ = try secretStore.getPluginSecret(plugin: plugin.identifier, key: secretKey)
            } catch {
                let value = promptForSecret(pluginName: plugin.name, key: secretKey)
                try secretStore.setPluginSecret(plugin: plugin.identifier, key: secretKey, value: value)
            }
        }
        if hasSecrets {
            try secretStore.setPluginSecret(
                plugin: plugin.identifier,
                key: SecretNamespace.pluginProtocolVersion,
                value: plugin.manifest.pluginProtocolVersion
            )
        }

        // Phase 3: Setup binary
        if let setup = plugin.manifest.setup, pluginConfig.isSetUp != true {
            let executable = resolveExecutable(setup.command, pluginDir: plugin.directory)
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                logger.error("[\(plugin.name)] Setup command not found or not executable: \(executable)")
                try pluginConfig.save(to: configURL)
                return
            }

            let secrets = fetchSecrets(for: plugin)
            let environment = buildSetupEnvironment(pluginConfig: pluginConfig, secrets: secrets)
            let args = substitute(args: setup.args, environment: environment)

            let dataDir = plugin.directory.appendingPathComponent(PluginDirectory.data)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let exitCode = try runSetupBinary(executable: executable, args: args, environment: environment, workingDirectory: dataDir)
            if exitCode == 0 {
                pluginConfig = pluginConfig.withIsSetUp(true)
            } else {
                logger.error("[\(plugin.name)] Setup binary exited with code \(exitCode)")
            }
        }

        try pluginConfig.save(to: configURL)
    }

    // MARK: - Prompting

    private mutating func promptForValue(
        pluginName: String, key: String, type: ConfigValueType, defaultValue: JSONValue
    ) -> JSONValue {
        let hasDefault = defaultValue != .null && defaultValue != .string("")
        while true {
            if hasDefault {
                let defaultStr = displayValue(defaultValue)
                print("[\(pluginName)] \(key) [\(defaultStr)]: ", terminator: "")
            } else {
                print("[\(pluginName)] \(key): ", terminator: "")
            }
            let input = inputSource.readLine() ?? ""
            if input.isEmpty, hasDefault {
                return defaultValue
            }
            if input.isEmpty {
                print("Value is required.")
                continue
            }
            if let parsed = parseInput(input, as: type) {
                return parsed
            }
            print("Invalid \(type.rawValue) value. Try again.")
        }
    }

    private mutating func promptForSecret(pluginName: String, key: String) -> String {
        while true {
            print("[\(pluginName)] \(key) (secret): ", terminator: "")
            let input = inputSource.readLine() ?? ""
            if !input.isEmpty { return input }
            print("Value is required.")
        }
    }

    // MARK: - Parsing

    private func parseInput(_ input: String, as type: ConfigValueType) -> JSONValue? {
        switch type {
        case .string:
            return .string(input)
        case .int:
            guard let intVal = Int(input) else { return nil }
            return .number(Double(intVal))
        case .float:
            guard let floatVal = Double(input) else { return nil }
            return .number(floatVal)
        case .bool:
            switch input.lowercased() {
            case "true", "yes", "y", "1": return .bool(true)
            case "false", "no", "n", "0": return .bool(false)
            default: return nil
            }
        }
    }

    private func displayValue(_ value: JSONValue) -> String {
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

    // MARK: - Setup binary helpers

    private func resolveExecutable(_ command: String, pluginDir: URL) -> String {
        if command.hasPrefix("/") { return command }
        return pluginDir.appendingPathComponent(command).path
    }

    private func fetchSecrets(for plugin: LoadedPlugin) -> [String: String] {
        var result: [String: String] = [:]
        for key in plugin.manifest.secretKeys {
            if let value = try? secretStore.getPluginSecret(plugin: plugin.identifier, key: key) {
                result[key] = value
            }
        }
        return result
    }

    private func buildSetupEnvironment(pluginConfig: PluginConfig, secrets: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in pluginConfig.values {
            let envKey = PluginEnvironment.configPrefix + key.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envKey] = displayValue(value)
        }
        for (key, value) in secrets {
            let envKey = PluginEnvironment.secretPrefix + key.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envKey] = value
        }
        return env
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

    private func runSetupBinary(executable: String, args: [String], environment: [String: String], workingDirectory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var mergedEnv = ProcessInfo.processInfo.environment
        mergedEnv.merge(environment) { _, new in new }
        process.environment = mergedEnv
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
