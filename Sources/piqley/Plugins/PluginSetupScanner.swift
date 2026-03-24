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
    let configStore: BasePluginConfigStore
    var inputSource: any InputSource
    private let logger = Logger(label: "piqley.setup-scanner")

    /// Runs setup scan for a single plugin.
    mutating func scan(plugin: LoadedPlugin, force: Bool = false) throws {
        var baseConfig: BasePluginConfig = if force {
            BasePluginConfig()
        } else {
            (try? configStore.load(for: plugin.identifier)) ?? BasePluginConfig()
        }

        // Phase 1: Config value resolution
        for entry in plugin.manifest.config {
            guard case let .value(key, type, defaultValue) = entry else { continue }
            if !force, let existing = baseConfig.values[key] {
                print("[\(plugin.name)] \(key) already set to: \(displayValue(existing))")
                continue
            }
            let resolved = promptForValue(pluginName: plugin.name, key: key, type: type, defaultValue: defaultValue)
            baseConfig.values[key] = resolved
        }

        // Phase 2: Secret validation with alias-based storage
        for entry in plugin.manifest.config {
            guard case let .secret(secretKey, _) = entry else { continue }
            let alias = defaultSecretAlias(pluginIdentifier: plugin.identifier, secretKey: secretKey)

            // Check if we already have this alias mapped and the secret exists
            if let existingAlias = baseConfig.secrets[secretKey] {
                if (try? secretStore.get(key: existingAlias)) != nil {
                    print("[\(plugin.name)] \(secretKey) (secret) already set")
                    continue
                }
            }

            // Prompt for secret value and store under alias
            let value = promptForSecret(pluginName: plugin.name, key: secretKey)
            try secretStore.set(key: alias, value: value)
            baseConfig.secrets[secretKey] = alias
        }

        // Phase 3: Setup binary
        if let setup = plugin.manifest.setup, baseConfig.isSetUp != true {
            let executable = resolveExecutable(setup.command, pluginDir: plugin.directory)
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                logger.error("[\(plugin.name)] Setup command not found or not executable: \(executable)")
                try configStore.save(baseConfig, for: plugin.identifier)
                return
            }

            let secrets = fetchSecrets(for: plugin, baseConfig: baseConfig)
            let environment = buildSetupEnvironment(baseConfig: baseConfig, secrets: secrets)
            let args = substitute(args: setup.args, environment: environment)

            let dataDir = plugin.directory.appendingPathComponent(PluginDirectory.data)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let exitCode = try runSetupBinary(
                executable: executable, args: args,
                environment: environment, workingDirectory: dataDir
            )
            if exitCode == 0 {
                baseConfig.isSetUp = true
            } else {
                logger.error("[\(plugin.name)] Setup binary exited with code \(exitCode)")
            }
        }

        try configStore.save(baseConfig, for: plugin.identifier)
    }

    /// Generates the default secret alias for a plugin secret key.
    static func defaultSecretAlias(pluginIdentifier: String, secretKey: String) -> String {
        "\(pluginIdentifier)-\(secretKey)"
    }

    private func defaultSecretAlias(pluginIdentifier: String, secretKey: String) -> String {
        Self.defaultSecretAlias(pluginIdentifier: pluginIdentifier, secretKey: secretKey)
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
            guard let input = inputSource.readLine() else {
                // EOF: return default if available, otherwise empty string
                return hasDefault ? defaultValue : .string("")
            }
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
            guard let input = inputSource.readLine() else {
                // EOF: return empty string to avoid infinite loop
                return ""
            }
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

    private func fetchSecrets(for _: LoadedPlugin, baseConfig: BasePluginConfig) -> [String: String] {
        var result: [String: String] = [:]
        for (key, alias) in baseConfig.secrets {
            if let value = try? secretStore.get(key: alias) {
                result[key] = value
            }
        }
        return result
    }

    private func buildSetupEnvironment(baseConfig: BasePluginConfig, secrets: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in baseConfig.values {
            let envKey = PluginEnvironment.configPrefix + ResolvedPluginConfig.sanitizeKey(key)
            env[envKey] = value.stringRepresentation
        }
        for (key, value) in secrets {
            let envKey = PluginEnvironment.secretPrefix + ResolvedPluginConfig.sanitizeKey(key)
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

    private func runSetupBinary(
        executable: String, args: [String],
        environment: [String: String], workingDirectory: URL
    ) throws -> Int32 {
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
