import Foundation
import PiqleyCore
// TermKit's Application.driver is a shared mutable static without concurrency annotations.
// @preconcurrency suppresses the warning — safe because TermKit is single-threaded on main.
@preconcurrency import TermKit

/// Entry point for the TUI rule editor wizard.
/// Manages the TermKit Application lifecycle and screen navigation.
///
/// Because TermKit's `Application.run()` calls `dispatchMain()` (which never returns)
/// and `Application.shutdown()` calls `exit()`, the wizard handles saving to disk
/// itself rather than returning control to the caller.
enum RulesWizardApp {
    /// Shared color scheme for all wizard screens.
    nonisolated(unsafe) static var wizardColorScheme: ColorScheme?

    /// Configuration needed to write changes back to disk.
    struct WriteBackConfig: Sendable {
        let pluginDir: URL
        let originalStages: [String: StageConfig]
    }

    /// Launch the wizard. This method does not return -- TermKit calls `exit()` on shutdown.
    /// Launch the wizard on the MainActor.
    /// Uses Application.begin() instead of Application.run() to avoid calling
    /// dispatchMain(), which conflicts with Swift's async runtime. The async
    /// runtime already services the main dispatch queue, so TermKit's GCD-based
    /// input handlers and display updates work without dispatchMain().
    @MainActor
    static func run(context: RuleEditingContext, writeBack: WriteBackConfig) async {
        Application.prepare(driverType: .unix)

        // Set black background color scheme on the top-level view.
        wizardColorScheme = makeBlackColorScheme()
        Application.top.colorScheme = wizardColorScheme!

        let stageScreen = StageSelectScreen(context: context, writeBack: writeBack)
        stageScreen.present()

        // begin() sets up layout, initial render, and starts event processing.
        Application.begin(toplevel: Application.top)

        // TermKit's input relies on FileHandle.readabilityHandler backed by
        // GCD dispatch sources. The Swift async MainActor executor processes
        // GCD main queue blocks but does NOT run the main RunLoop, which some
        // dispatch sources may depend on. We pump the RunLoop from a timer-based
        // GCD source to ensure all I/O sources fire.
        let runLoopTimer = DispatchSource.makeTimerSource(queue: .main)
        runLoopTimer.schedule(deadline: .now(), repeating: .milliseconds(16))
        runLoopTimer.setEventHandler {
            RunLoop.main.run(mode: .default, before: Date())
        }
        runLoopTimer.resume()

        // Keep the async task alive — TermKit's shutdown() calls exit().
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Creates a color scheme with black background for the wizard.
    @MainActor
    private static func makeBlackColorScheme() -> ColorScheme {
        let drv = Application.driver
        return ColorScheme(
            normal: drv.makeAttribute(fore: .white, back: .black),
            focus: drv.makeAttribute(fore: .black, back: .white),
            hotNormal: drv.makeAttribute(fore: .white, back: .black, flags: .bold),
            hotFocus: drv.makeAttribute(fore: .black, back: .white)
        )
    }

    /// Clean up terminal and exit the process.
    /// We can't use Application.shutdown() because it relies on dispatchMain().
    static func exitWizard() -> Never {
        // Restore terminal state
        Application.driver.end()
        exit(0)
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
