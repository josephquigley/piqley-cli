import ArgumentParser
import Foundation

extension PluginCommand {
    struct CreateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Scaffold a new plugin project from an SDK template"
        )

        @Argument(help: "Target directory for the new plugin project")
        var targetDirectory: String

        @Option(name: .long, help: "Programming language for the template (default: swift)")
        var language: String = "swift"

        @Option(name: .long, help: "Plugin name (derived from target directory if omitted)")
        var name: String?

        @Option(name: .long, help: "SDK repository URL")
        var sdkRepoURL: String = "https://github.com/josephquigley/piqley-plugin-sdk"

        var resolvedPluginName: String {
            name ?? URL(fileURLWithPath: targetDirectory).lastPathComponent
        }

        var resolvedLanguage: String {
            language.lowercased()
        }

        func validatePluginName() throws {
            try InitSubcommand.validatePluginName(resolvedPluginName)
        }

        func run() async throws {
            let pluginName = resolvedPluginName
            try InitSubcommand.validatePluginName(pluginName)

            let targetURL = URL(fileURLWithPath: targetDirectory)
            try TemplateFetcher.validateTargetDirectory(targetURL)

            let cliVersion = try SemVer.parse(AppConstants.version)

            print("Resolving SDK version compatible with CLI v\(cliVersion.versionString)...")
            let sdkVersion = try SDKVersionResolver.resolve(
                cliVersion: cliVersion, repoURL: sdkRepoURL
            )
            print("Found SDK v\(sdkVersion.versionString)")

            print("Downloading template...")
            let (templateDir, tempDir) = try TemplateFetcher.fetchAndExtractTemplate(
                repoURL: sdkRepoURL, tag: sdkVersion, language: resolvedLanguage
            )
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try TemplateFetcher.copyTemplate(from: templateDir, to: targetURL)
            try TemplateFetcher.applyTemplateSubstitutions(
                in: targetURL, pluginName: pluginName, sdkVersion: sdkVersion.versionString
            )

            print("Created plugin '\(pluginName)' at \(targetURL.path)")
        }
    }
}
