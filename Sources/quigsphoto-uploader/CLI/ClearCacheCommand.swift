import ArgumentParser
import Foundation

struct ClearCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-cache",
        abstract: "Delete upload and email log caches"
    )

    @Flag(help: "Only delete the upload log")
    var uploadLog = false

    @Flag(help: "Only delete the email log")
    var emailLog = false

    func run() throws {
        let configDir = AppConfig.configDirectory
        let uploadLogPath = configDir.appendingPathComponent("upload-log.jsonl").path
        let emailLogPath = configDir.appendingPathComponent("email-log.jsonl").path

        let clearAll = !uploadLog && !emailLog

        var deleted: [String] = []

        if clearAll || uploadLog {
            if FileManager.default.fileExists(atPath: uploadLogPath) {
                try FileManager.default.removeItem(atPath: uploadLogPath)
                deleted.append("upload-log.jsonl")
            }
        }

        if clearAll || emailLog {
            if FileManager.default.fileExists(atPath: emailLogPath) {
                try FileManager.default.removeItem(atPath: emailLogPath)
                deleted.append("email-log.jsonl")
            }
        }

        if deleted.isEmpty {
            print("No cache files to delete.")
        } else {
            print("Deleted: \(deleted.joined(separator: ", "))")
        }
    }
}
