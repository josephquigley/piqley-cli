import Foundation
import PiqleyCore

enum PipelineEditor {
    enum AddError: Error, CustomStringConvertible {
        case pluginNotFound(String)
        case noStageFile(plugin: String, stage: String)
        case alreadyInStage(plugin: String, stage: String)
        case invalidStage(String)

        var description: String {
            switch self {
            case let .pluginNotFound(id): "Plugin '\(id)' not found"
            case let .noStageFile(plugin, stage): "Plugin '\(plugin)' has no stage file for '\(stage)'"
            case let .alreadyInStage(plugin, stage): "Plugin '\(plugin)' is already in '\(stage)' pipeline"
            case let .invalidStage(stage): "'\(stage)' is not a valid pipeline stage"
            }
        }
    }

    enum RemoveError: Error, CustomStringConvertible {
        case pluginNotInStage(plugin: String, stage: String)
        case invalidStage(String)

        var description: String {
            switch self {
            case let .pluginNotInStage(plugin, stage): "Plugin '\(plugin)' is not in '\(stage)' pipeline"
            case let .invalidStage(stage): "'\(stage)' is not a valid pipeline stage"
            }
        }
    }

    static func validateAdd(
        pluginId: String,
        stage: String,
        workflow: Workflow,
        discoveredPlugins: [LoadedPlugin]
    ) throws {
        let validStages = Set(Hook.allCases.map(\.rawValue))
        guard validStages.contains(stage) else {
            throw AddError.invalidStage(stage)
        }
        guard let plugin = discoveredPlugins.first(where: { $0.identifier == pluginId }) else {
            throw AddError.pluginNotFound(pluginId)
        }
        guard plugin.stages[stage] != nil else {
            throw AddError.noStageFile(plugin: pluginId, stage: stage)
        }
        let current = Set(workflow.pipeline[stage] ?? [])
        guard !current.contains(pluginId) else {
            throw AddError.alreadyInStage(plugin: pluginId, stage: stage)
        }
    }

    static func validateRemove(
        pluginId: String,
        stage: String,
        workflow: Workflow
    ) throws {
        let validStages = Set(Hook.allCases.map(\.rawValue))
        guard validStages.contains(stage) else {
            throw RemoveError.invalidStage(stage)
        }
        let current = workflow.pipeline[stage] ?? []
        guard current.contains(pluginId) else {
            throw RemoveError.pluginNotInStage(plugin: pluginId, stage: stage)
        }
    }

    /// Find plugins that depend on the given plugin in any stage.
    static func dependents(
        of pluginId: String,
        in workflow: Workflow,
        discoveredPlugins: [LoadedPlugin]
    ) -> [String] {
        discoveredPlugins
            .filter { $0.manifest.dependencyIdentifiers.contains(pluginId) }
            .filter { plugin in
                workflow.pipeline.values.flatMap(\.self).contains(plugin.identifier)
            }
            .map(\.identifier)
    }
}
