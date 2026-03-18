import Foundation

/// Tracks plugins that have failed during the current run.
/// A blocked plugin is skipped for all subsequent hooks in the run.
/// Not thread-safe — the pipeline is sequential, so no locking needed.
final class PluginBlocklist: @unchecked Sendable {
    private var blocked: Set<String> = []

    func block(_ pluginName: String) {
        blocked.insert(pluginName)
    }

    func isBlocked(_ pluginName: String) -> Bool {
        blocked.contains(pluginName)
    }
}
