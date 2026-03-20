import ArgumentParser
import Foundation
import PiqleyCore

extension ConfigCommand {
    struct AddPluginSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-plugin",
            abstract: "Add a plugin to a pipeline stage"
        )

        @Argument(help: "Plugin identifier")
        var pluginIdentifier: String

        @Argument(help: "Pipeline stage (pre-process, post-process, publish, post-publish)")
        var stage: String

        @Option(help: "Position in the stage (0-based index, appends if omitted)")
        var position: Int?

        func run() throws {
            var config = try AppConfig.load()
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            try PipelineEditor.validateAdd(
                pluginId: pluginIdentifier, stage: stage,
                config: config, discoveredPlugins: plugins
            )

            var list = config.pipeline[stage] ?? []
            if let pos = position, pos >= 0, pos <= list.count {
                list.insert(pluginIdentifier, at: pos)
            } else {
                list.append(pluginIdentifier)
            }
            config.pipeline[stage] = list
            try config.save()

            print("Added '\(pluginIdentifier)' to \(stage) pipeline")
        }
    }
}
