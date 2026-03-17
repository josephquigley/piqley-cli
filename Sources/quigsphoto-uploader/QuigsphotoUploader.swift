import ArgumentParser
import Foundation
import Logging

@main
struct QuigsphotoUploader: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quigsphoto-uploader",
        abstract: "Process and publish photos to Ghost CMS",
        subcommands: [ProcessCommand.self, SetupCommand.self, ClearCacheCommand.self]
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

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        // StreamLogHandler includes [label] in the output — we bypass it and format ourselves
        let timestamp = CleanLogHandler.timestamp()
        let levelStr = "\(level)".uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
        FileHandle.standardError.write(Data("\(timestamp) \(levelStr) \(message)\n".utf8))
    }

    private static func timestamp() -> String {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: now)
    }
}
