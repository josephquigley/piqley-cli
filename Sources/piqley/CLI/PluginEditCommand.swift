import ArgumentParser
import Foundation
import Logging
import PiqleyCore

extension PluginCommand {
    struct EditSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit rules for a mutable plugin"
        )

        @Argument(help: "Plugin identifier (shows picker if omitted)")
        var pluginIdentifier: String?

        func run() throws {
            let (registry, allPlugins) = try WorkflowCommand.loadRegistryAndPlugins()

            let mutablePlugins = allPlugins.filter { $0.manifest.type == .mutable }
            let staticCount = allPlugins.count - mutablePlugins.count

            let selected: LoadedPlugin
            if let pluginIdentifier {
                guard let plugin = allPlugins.first(where: { $0.identifier == pluginIdentifier }) else {
                    throw CleanError("No plugin found with identifier '\(pluginIdentifier)'.")
                }
                guard plugin.manifest.type == .mutable else {
                    throw CleanError(
                        "'\(plugin.name)' is a static plugin and cannot be modified. "
                            + "Config values can be changed with 'piqley plugin setup'."
                    )
                }
                selected = plugin
            } else {
                guard !mutablePlugins.isEmpty else {
                    throw CleanError("No editable plugins installed. Create one with 'piqley plugin init'.")
                }
                guard isatty(STDIN_FILENO) != 0 else {
                    throw CleanError("No plugin specified and stdin is not a terminal.")
                }

                let terminal = RawTerminal()
                let items = mutablePlugins.map {
                    "\($0.identifier)  \(ANSI.dim)\($0.name)\(ANSI.reset)"
                }
                let footerNote = staticCount > 0
                    ? "\n\(ANSI.dim)(\(staticCount) unmodifiable plugin\(staticCount == 1 ? "" : "s")"
                    + " not shown. Use the workflow rules editor to adjust their default behavior.)\(ANSI.reset)"
                    : ""
                guard let idx = terminal.selectFromFilterableList(
                    title: "Select a plugin to edit\(footerNote)",
                    items: items
                ) else {
                    terminal.restore()
                    return
                }
                terminal.restore()
                selected = mutablePlugins[idx]
            }

            let manifest = selected.manifest
            let pluginDir = selected.directory
            let pluginsDir = PipelineOrchestrator.defaultPluginsDirectory

            // Build field dependencies from manifest dependencies
            var deps: [FieldDiscovery.DependencyInfo] = []
            for depId in manifest.dependencyIdentifiers {
                let depManifestURL = pluginsDir
                    .appendingPathComponent(depId)
                    .appendingPathComponent(PluginFile.manifest)
                guard let depData = try? Data(contentsOf: depManifestURL),
                      let depManifest = try? JSONDecoder.piqley.decode(PluginManifest.self, from: depData)
                else { continue }
                if !depManifest.fields.isEmpty {
                    deps.append(FieldDiscovery.DependencyInfo(identifier: depId, fields: depManifest.fields))
                }
            }

            // Add the plugin's own fields
            if !manifest.fields.isEmpty {
                deps.append(FieldDiscovery.DependencyInfo(
                    identifier: selected.identifier,
                    fields: manifest.fields
                ))
            }

            // Load stages from plugin directory
            let knownHooks = registry.allKnownNames
            var (stages, _) = PluginDiscovery.loadStages(
                from: pluginDir,
                knownHooks: knownHooks,
                logger: Logger(label: "piqley.plugin.edit")
            )

            // Ensure all known stages are present (in-memory only)
            for stageName in registry.executionOrder where stages[stageName] == nil {
                stages[stageName] = StageConfig(preRules: nil, binary: nil, postRules: nil)
            }

            let availableFields = FieldDiscovery.buildAvailableFields(dependencies: deps)
            let context = RuleEditingContext(
                availableFields: availableFields,
                pluginIdentifier: selected.identifier,
                stages: stages
            )

            let wizard = RulesWizard(context: context, rulesDir: pluginDir)
            try wizard.run()
        }
    }
}
