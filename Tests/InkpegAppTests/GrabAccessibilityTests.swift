import XCTest
import AppKit
import InkpegCore
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


extension GrabAccessibilityTests {
    @MainActor
    func testCardLabelIncludesKindShortTitleAndPosition() async throws {
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-label-test-" + UUID().uuidString)), line = Line(store: store)
        for title in ["First synthetic title", "Second synthetic title"] { _ = try await store.importMaterial(.text(title, SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max) }
        try await line.load()
        let label = line.cardAccessibilityLabel(line.items[1])
        XCTAssertTrue(label.contains(L(.inputText)))
        XCTAssertTrue(label.contains("Second synthetic title"))
        XCTAssertTrue(label.contains(String(format: L(.shelfPosition), 2, 2)))
        var item = line.items[0]; item.displayTitle = String(repeating: "Long ", count: 80)
        XCTAssertLessThan(line.cardAccessibilityLabel(item).count, 100)
    }
}
