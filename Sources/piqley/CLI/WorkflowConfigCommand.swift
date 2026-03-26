import ArgumentParser
import Foundation
import PiqleyCore

extension WorkflowCommand {
    struct ConfigSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Set per-plugin config overrides for a workflow"
        )

        @Argument(help: "Workflow name")
        var workflowName: String

        @Argument(help: "Plugin identifier (reverse-TLD)")
        var pluginIdentifier: String

        @Option(name: .long, parsing: .singleValue, help: "Set a config value override (key=value)")
        var set: [String] = []

        @Option(name: .customLong("set-secret"), parsing: .singleValue, help: "Set a secret alias override (KEY=alias-name)")
        var setSecret: [String] = []

        func run() throws {
            var workflow = try WorkflowStore.load(name: workflowName)

            if !set.isEmpty || !setSecret.isEmpty {
                try runFlagMode(workflow: &workflow)
            } else {
                try runInteractiveMode(workflow: &workflow)
            }

            try WorkflowStore.save(workflow)
            print("Updated config for '\(pluginIdentifier)' in workflow '\(workflowName)'")
        }

        // MARK: - Flag mode

        private func runFlagMode(workflow: inout Workflow) throws {
            var override = workflow.config[pluginIdentifier] ?? WorkflowPluginConfig()

            for pair in set {
                let (key, value) = try parsePair(pair)
                if override.values == nil { override.values = [:] }
                override.values?[key] = .string(value)
            }

            for pair in setSecret {
                let (key, alias) = try parsePair(pair)
                if override.secrets == nil { override.secrets = [:] }
                override.secrets?[key] = alias
            }

            workflow.config[pluginIdentifier] = override
        }

        // MARK: - Interactive mode

        private func runInteractiveMode(workflow: inout Workflow) throws {
            let configStore = BasePluginConfigStore.default
            let baseConfig = try configStore.load(for: pluginIdentifier) ?? BasePluginConfig()

            let (_, plugins) = try WorkflowCommand.loadRegistryAndPlugins()
            guard let plugin = plugins.first(where: { $0.identifier == pluginIdentifier }) else {
                throw ValidationError("Plugin '\(pluginIdentifier)' is not installed")
            }

            var override = workflow.config[pluginIdentifier] ?? WorkflowPluginConfig()

            // Prompt through config values
            for entry in plugin.manifest.config {
                guard case let .value(key, type, _, _) = entry else { continue }
                let currentValue = override.values?[key] ?? baseConfig.values[key]
                let currentDisplay = currentValue.map { displayValue($0) } ?? "(base default)"

                print("[\(plugin.name)] \(key) [\(currentDisplay)]: ", terminator: "")
                guard let input = readLine(strippingNewline: true), !input.isEmpty else {
                    continue // keep existing
                }

                if let parsed = parseInput(input, as: type) {
                    if override.values == nil { override.values = [:] }
                    override.values?[key] = parsed
                } else {
                    print("Invalid \(type.rawValue) value, keeping current.")
                }
            }

            // Prompt through secret aliases
            for entry in plugin.manifest.config {
                guard case let .secret(secretKey, _, _) = entry else { continue }
                let currentAlias = override.secrets?[secretKey] ?? baseConfig.secrets[secretKey]
                let currentDisplay = currentAlias ?? "(base default)"

                print("[\(plugin.name)] \(secretKey) alias [\(currentDisplay)]: ", terminator: "")
                guard let input = readLine(strippingNewline: true), !input.isEmpty else {
                    continue // keep existing
                }

                if override.secrets == nil { override.secrets = [:] }
                override.secrets?[secretKey] = input
            }

            workflow.config[pluginIdentifier] = override
        }

        // MARK: - Helpers

        private func parsePair(_ pair: String) throws -> (String, String) {
            guard let eqIndex = pair.firstIndex(of: "=") else {
                throw ValidationError("Invalid format '\(pair)'. Expected key=value")
            }
            let key = String(pair[pair.startIndex ..< eqIndex])
            let value = String(pair[pair.index(after: eqIndex)...])
            guard !key.isEmpty else {
                throw ValidationError("Key cannot be empty in '\(pair)'")
            }
            return (key, value)
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
    }
}
