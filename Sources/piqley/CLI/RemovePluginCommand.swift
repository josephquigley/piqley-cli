import ArgumentParser
import Foundation
import PiqleyCore

extension ConfigCommand {
    struct RemovePluginSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove-plugin",
            abstract: "Remove a plugin from a pipeline stage"
        )

        @Argument(help: "Plugin identifier")
        var pluginIdentifier: String

        @Argument(help: "Pipeline stage (pre-process, post-process, publish, post-publish)")
        var stage: String

        func run() throws {
            var config = try AppConfig.load()
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory
            let discovery = PluginDiscovery(pluginsDirectory: pluginsDir)
            let plugins = try discovery.loadManifests()

            try PipelineEditor.validateRemove(
                pluginId: pluginIdentifier, stage: stage, config: config
            )

            let dependents = PipelineEditor.dependents(
                of: pluginIdentifier, in: config, discoveredPlugins: plugins
            )
            if !dependents.isEmpty {
                print("Warning: The following plugins depend on '\(pluginIdentifier)': \(dependents.joined(separator: ", "))")
            }

            var list = config.pipeline[stage] ?? []
            list.removeAll { $0 == pluginIdentifier }
            config.pipeline[stage] = list
            try config.save()

            print("Removed '\(pluginIdentifier)' from \(stage) pipeline")
        }
    }
}
