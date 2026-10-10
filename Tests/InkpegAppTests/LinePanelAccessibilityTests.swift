import XCTest
import AppKit
@testable import Inkpeg

final class LinePanelAccessibilityTests: XCTestCase {
    @MainActor
    func testAccessibilityRaiseRevealsWithoutTakingKeyboardFocus() {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView())
        var revealed = false
        panel.onAccessibilityReveal = { revealed = true }
        XCTAssertTrue(panel.accessibilityPerformRaise())
        XCTAssertTrue(revealed)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
}
