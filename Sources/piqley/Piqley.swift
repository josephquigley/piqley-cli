import ArgumentParser
import Foundation
import Logging

@main
struct Piqley: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AppConstants.name,
        abstract: "Process and publish photos to Ghost CMS",
        version: AppConstants.version,
        subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self, VerifyCommand.self]
    )

    static func main() async {
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

    func log(level _: Logger.Level, message: Logger.Message, metadata _: Logger.Metadata?, source _: String, file _: String, function _: String, line _: UInt) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
