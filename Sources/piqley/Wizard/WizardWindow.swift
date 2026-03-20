import Foundation
import TermKit

/// A Window subclass that supports a closure-based key handler.
/// Allows screens to intercept key events without further subclassing.
class WizardWindow: Window {
    /// Called when a key event is received. Return `true` if handled.
    nonisolated(unsafe) var onKey: ((KeyEvent) -> Bool)?

    override init(_ title: String? = nil, internalPadding: Int = 0) {
        super.init(title, internalPadding: internalPadding)
        if let scheme = RulesWizardApp.wizardColorScheme {
            colorScheme = scheme
        }
    }

    override func processKey(event: KeyEvent) -> Bool {
        if let handler = onKey, handler(event) {
            return true
        }
        return super.processKey(event: event)
    }
}

/// A Toplevel subclass with a closure-based cold key handler.
/// Cold keys are processed AFTER focused views, so letter shortcuts
/// don't interfere with text input but still work when no view consumes them.
class WizardToplevel: Toplevel {
    nonisolated(unsafe) var onColdKey: ((KeyEvent) -> Bool)?

    override func processColdKey(event: KeyEvent) -> Bool {
        if let handler = onColdKey, handler(event) {
            return true
        }
        return super.processColdKey(event: event)
    }
}

/// Creates a WizardToplevel with the wizard's color scheme applied.
func makeWizardToplevel() -> WizardToplevel {
    let top = WizardToplevel()
    top.fill()
    if let scheme = RulesWizardApp.wizardColorScheme {
        top.colorScheme = scheme
    }
    return top
}
