import Foundation
import PiqleyCore
import TermKit

/// Entry point for the TUI rule editor wizard.
/// Manages the TermKit Application lifecycle and screen navigation.
///
/// Because TermKit's `Application.run()` calls `dispatchMain()` (which never returns)
/// and `Application.shutdown()` calls `exit()`, the wizard handles saving to disk
/// itself rather than returning control to the caller.
enum RulesWizardApp {
    /// Configuration needed to write changes back to disk.
    struct WriteBackConfig: Sendable {
        let pluginDir: URL
        let originalStages: [String: StageConfig]
    }

    /// Launch the wizard. This method does not return -- TermKit calls `exit()` on shutdown.
    @MainActor
    static func run(context: RuleEditingContext, writeBack: WriteBackConfig) {
        Application.prepare()

        let stageScreen = StageSelectScreen(context: context, writeBack: writeBack)
        stageScreen.present()

        // Application.run() calls dispatchMain() internally and never returns.
        // TermKit's shutdown() calls exit(), so this is effectively a one-way trip.
        Application.run()
    }

    /// Writes modified stages back to disk. Called by the wizard before shutdown.
    static func saveStages(_ stages: [String: StageConfig], to pluginDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (hookName, stageConfig) in stages {
            let data = try encoder.encode(stageConfig)
            let stageFile = pluginDir
                .appendingPathComponent("\(PluginFile.stagePrefix)\(hookName)\(PluginFile.stageSuffix)")
            try data.write(to: stageFile, options: .atomic)
        }
    }
}
