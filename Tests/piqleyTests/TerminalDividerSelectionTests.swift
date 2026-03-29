import Foundation
import Testing
@testable import piqley

@Suite("selectFromListWithDivider")
struct TerminalDividerSelectionTests {
    @Test("divider index is skipped when navigating down")
    func dividerSkippedDown() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorDown, cursor: 1, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 3)
    }

    @Test("divider index is skipped when navigating up")
    func dividerSkippedUp() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorUp, cursor: 3, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 1)
    }

    @Test("navigation without divider works normally")
    func noDivider() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorDown, cursor: 0, itemCount: 3, dividerIndex: nil
        )
        #expect(result == 1)
    }

    @Test("cursor does not go below last item")
    func cursorClamped() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorDown, cursor: 3, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 3)
    }

    @Test("cursor does not go above first item")
    func cursorClampedTop() {
        let result = RawTerminal.navigateWithDivider(
            key: .cursorUp, cursor: 0, itemCount: 4, dividerIndex: 2
        )
        #expect(result == 0)
    }
}
