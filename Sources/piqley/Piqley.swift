import ArgumentParser
import Foundation
import Logging
import PiqleyCore

@main
struct Piqley: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AppConstants.name,
        abstract: "Plugin-driven photographer workflow engine",
        version: AppConstants.version,
        subcommands: [
            ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self,
            SecretCommand.self, PluginCommand.self, WorkflowCommand.self,
            UninstallCommand.self,
        ]
    )

    static func main() async {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return CleanLogHandler(underlying: handler)
        }

        do {
            // Migrate old config.json sidecars to BasePluginConfig layout
            try? ConfigMigrator.migrateIfNeeded(
                pluginsDirectory: PipelineOrchestrator.defaultPluginsDirectory,
                configStore: .default,
                secretStore: makeDefaultSecretStore()
            )

            // Seed default workflow if none exist
            let stagesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(PiqleyPath.stages)
            let seedRegistry = try StageRegistry.load(from: stagesDir)
            try WorkflowStore.seedDefault(activeStages: seedRegistry.executionOrder)

            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}

/// Log handler that strips the `[label]` metadata prefix from output
struct CleanLogHandler: LogHandler {
    var underlying: StreamLogHandler

    var logLevel: Logger.Level {
        get { underlying.logLevel }
        set { underlying.logLevel = newValue }
    }

    var metadata: Logger.Metadata {
        get { underlying.metadata }
        set { underlying.metadata = newValue }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { underlying[metadataKey: key] }
        set { underlying[metadataKey: key] = newValue }
    }

    // swiftlint:disable:next function_parameter_count
    func log(
        level _: Logger.Level, message: Logger.Message, metadata _: Logger.Metadata?,
        source _: String, file _: String, function _: String, line _: UInt
    ) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
