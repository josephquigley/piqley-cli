import ArgumentParser
import Foundation
import Logging

/// The true process entry point. Intercepts the rule editor command and runs it
/// synchronously before the async runtime starts. All other commands are forwarded
/// to the async `Piqley` command.
///
/// Why: TermKit's `Application.run()` calls `dispatchMain()` which requires exclusive
/// ownership of the main thread. Swift's async runtime (`main() async`) also owns the
/// main thread via `swift_task_asyncMainDrainQueue`. These are incompatible — calling
/// `dispatchMain()` from any async context crashes. The only solution is to run TermKit
/// before the async runtime starts.
@main
enum PiqleyMain {
    static func main() {
        let args = CommandLine.arguments
        let isRulesEdit = args.contains("rules") && (args.contains("edit") || {
            guard let rulesIdx = args.firstIndex(of: "rules") else { return false }
            let nextIdx = args.index(after: rulesIdx)
            return nextIdx < args.endIndex && !args[nextIdx].hasPrefix("-")
        }())

        if isRulesEdit {
            // Run synchronously — no async runtime, no logging bootstrap.
            // TermKit bootstraps its own logging and calls dispatchMain().
            do {
                var command = try Piqley.parseAsRoot()
                try command.run()
            } catch {
                Piqley.exit(withError: error)
            }
        } else {
            // All other commands go through the async entry point.
            Piqley.asyncMain()
        }
    }
}

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

    /// Async entry point for all non-rules commands.
    static func asyncMain() {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return CleanLogHandler(underlying: handler)
        }

        do {
            var command = try parseAsRoot()
            if let asyncCommand = command as? AsyncParsableCommand {
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    do {
                        var cmd = asyncCommand
                        try await cmd.run()
                    } catch {
                        Self.exit(withError: error)
                    }
                    semaphore.signal()
                }
                semaphore.wait()
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
