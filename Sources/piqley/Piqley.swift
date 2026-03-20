import ArgumentParser
import Foundation
import Logging

@main
struct Piqley: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AppConstants.name,
        abstract: "Plugin-driven photographer workflow engine",
        version: AppConstants.version,
        subcommands: [
            ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self,
            SecretCommand.self, PluginCommand.self, ConfigCommand.self,
            UninstallCommand.self,
        ]
    )

    static func main() async {
        // Skip logging bootstrap when launching the rule editor wizard.
        // TermKit's Application.prepare() bootstraps its own logging system
        // and LoggingSystem.bootstrap can only be called once per process.
        let args = CommandLine.arguments
        let isRulesEdit = args.contains("rules") && (args.contains("edit") || {
            // "rules <plugin-id>" without explicit "edit" defaults to edit
            guard let rulesIdx = args.firstIndex(of: "rules") else { return false }
            let nextIdx = args.index(after: rulesIdx)
            return nextIdx < args.endIndex && !args[nextIdx].hasPrefix("-")
        }())

        if !isRulesEdit {
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = .info
                return CleanLogHandler(underlying: handler)
            }
        }

        do {
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
