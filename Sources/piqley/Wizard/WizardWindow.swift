import TermKit

/// A Window subclass that supports a closure-based key handler.
/// Allows screens to intercept key events without further subclassing.
class WizardWindow: Window {
    /// Called when a key event is received. Return `true` if handled.
    nonisolated(unsafe) var onKey: ((KeyEvent) -> Bool)?

    override func processKey(event: KeyEvent) -> Bool {
        if let handler = onKey, handler(event) {
            return true
        }
        return super.processKey(event: event)
    }
}
