import Foundation
import PiqleyCore
// TermKit's Application.driver is a shared mutable static without concurrency annotations.
// @preconcurrency suppresses the warning — safe because TermKit is single-threaded on main.
@preconcurrency import TermKit

/// Entry point for the TUI rule editor wizard.
enum RulesWizardApp {
    /// Shared color scheme for all wizard screens.
    nonisolated(unsafe) static var wizardColorScheme: ColorScheme?

    /// The single window used for the entire wizard lifetime.
    nonisolated(unsafe) static var mainWindow: WizardWindow?

    /// Configuration needed to write changes back to disk.
    struct WriteBackConfig: Sendable {
        let pluginDir: URL
        let originalStages: [String: StageConfig]
    }

    @MainActor
    static func run(context: RuleEditingContext, writeBack: WriteBackConfig) async {
        Application.prepare(driverType: .unix)

        wizardColorScheme = makeBlackColorScheme()
        Application.top.colorScheme = wizardColorScheme!

        // Create a single window that lives for the entire wizard session.
        let win = WizardWindow("piqley rule editor")
        win.fill()
        if let scheme = wizardColorScheme {
            win.colorScheme = scheme
        }
        Application.top.addSubview(win)
        mainWindow = win

        let stageScreen = StageSelectScreen(context: context, writeBack: writeBack)
        stageScreen.show(in: win)

        Application.begin(toplevel: Application.top)

        // Pump the RunLoop so TermKit's FileHandle.readabilityHandler fires.
        let runLoopTimer = DispatchSource.makeTimerSource(queue: .main)
        runLoopTimer.schedule(deadline: .now(), repeating: .milliseconds(16))
        runLoopTimer.setEventHandler {
            RunLoop.main.run(mode: .default, before: Date())
        }
        runLoopTimer.resume()

        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

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

    /// Clean up terminal and exit.
    static func exitWizard() -> Never {
        Application.driver.end()
        exit(0)
    }

    /// Writes modified stages back to disk.
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
