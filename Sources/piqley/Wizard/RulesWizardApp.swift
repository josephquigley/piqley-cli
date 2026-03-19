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

    /// Launch the wizard. This method does not return -- it calls `exit()` via TermKit.
    static func run(context: RuleEditingContext, writeBack: WriteBackConfig) -> Never {
        // TermKit requires MainActor, so dispatch to main
        DispatchQueue.main.async {
            Application.prepare()

            let stageScreen = StageSelectScreen(context: context, writeBack: writeBack)
            stageScreen.present()

            Application.run()
        }

        // Application.run() uses dispatchMain() internally, but we need to keep
        // this thread alive. dispatchMain() is called inside Application.run(),
        // so we just need to block here.
        dispatchMain()
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
