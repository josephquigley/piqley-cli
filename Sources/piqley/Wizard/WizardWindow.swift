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

/// Creates a Toplevel with the wizard's color scheme applied.
func makeWizardToplevel() -> Toplevel {
    let top = Toplevel()
    top.fill()
    if let scheme = RulesWizardApp.wizardColorScheme {
        top.colorScheme = scheme
    }
    return top
}
