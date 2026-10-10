import XCTest
import AppKit
@testable import Inkpeg

final class GrabAccessibilityTests: XCTestCase {
    @MainActor
    func testAccessibleCardPressInvokesTheSameCopyAction() {
        let view = GrabView()
        var copyActions = 0
        view.onClick = { copyActions += 1 }
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(copyActions, 1)
    }
}
