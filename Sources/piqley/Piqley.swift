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

    /// Custom entry point that intercepts the rule editor before the async runtime starts.
    /// TermKit's Application.run() calls dispatchMain() which is incompatible with
    /// Swift's cooperative async executor.
    static func main() async {
        let args = CommandLine.arguments
        let isRulesEdit = args.contains("rules") && (args.contains("edit") || {
            guard let rulesIdx = args.firstIndex(of: "rules") else { return false }
            let nextIdx = args.index(after: rulesIdx)
            return nextIdx < args.endIndex && !args[nextIdx].hasPrefix("-")
        }())

        if isRulesEdit {
            // TermKit needs dispatchMain() which conflicts with async runtime.
            // Parse and run on the main queue, then keep the async task alive
            // indefinitely — TermKit's shutdown() calls exit() to end the process.
            DispatchQueue.main.async {
                do {
                    var command = try parseAsRoot()
                    try command.run()
                } catch {
                    Self.exit(withError: error)
                }
            }
            // Yield forever — TermKit's exit() terminates the process.
            while true {
                await Task.yield()
                try? await Task.sleep(for: .seconds(60))
            }
        }

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return CleanLogHandler(underlying: handler)
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
