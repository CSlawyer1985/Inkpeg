import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class IntakeInteractionTests: XCTestCase {
    @MainActor
    func testPasteAndSettingsAreAvailableInTheMenu() {
        let previous = appLocalizer; appLocalizer = Localizer(localeIdentifier: "zh-Hans")
        defer { appLocalizer = previous }
        let delegate = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: URL(fileURLWithPath: "/tmp/inkpeg-input-menu-" + UUID().uuidString)))
        let menu = NSMenu(); delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "粘贴挂入" })
        XCTAssertTrue(menu.items.contains { $0.title == "设置…" })
    }
    @MainActor
    func testDropSelectsCopyAndProducesFileRequestsWithDropSources() throws {
        let board = NSPasteboard(name: .init("InkpegDrop-" + UUID().uuidString))
        let file = URL(fileURLWithPath: "/tmp/inkpeg-drop-" + UUID().uuidString + ".txt")
        let bytes = Data("合成拖入材料".utf8); try bytes.write(to: file)
        let item = NSPasteboardItem(); item.setString(file.absoluteString, forType: .fileURL); item.setString("辅助名称", forType: .string)
        XCTAssertTrue(board.writeObjects([item]))
        let target = LineDropTarget(); var count = 0, received: [ImportRequest] = []
        target.onHover = { count = $0 }; target.onReceive = { received = $0; return true }
        XCTAssertEqual(target.updateHover(from: board), .copy)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(target.receive(from: board))
        guard case .file(let url, let origin) = received.first else { return XCTFail("Drop must produce file input") }
        XCTAssertEqual(url, file); XCTAssertEqual(origin, .drop)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        target.resetHover(); XCTAssertEqual(count, 0)
        target.canReceive = { false }
        XCTAssertEqual(target.updateHover(from: board), [])
        XCTAssertFalse(target.receive(from: board))
    }
    @MainActor
    func testDisabledFileAutomaticModeDoesNotAccessItsRepresentation() throws {
        let board = NSPasteboard(name: .init("InkpegFiltered-" + UUID().uuidString))
        let item = NSPasteboardItem(); item.setString("file://remote-host/never-read", forType: .fileURL); item.setString("辅助文字", forType: .string)
        XCTAssertTrue(board.writeObjects([item]))
        let input = try SystemClipboardGateway(pasteboard: board).readSnapshot(allowing: ClipboardPreference(enabled: true, files: false))
        XCTAssertTrue(input.requests.isEmpty)
    }
    func testDropRegionIsLimitedToTheRopeBand() {
        let rect = LineInputLayout.region(width: 1200)
        XCTAssertTrue(rect.contains(CGPoint(x: 600, y: 30)))
        XCTAssertFalse(rect.contains(CGPoint(x: 600, y: 120)))
        XCTAssertFalse(rect.contains(CGPoint(x: 0, y: 30)))
        XCTAssertLessThanOrEqual(rect.height, 64)
    }
}
