import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class IntakeAdapterAuditTests: XCTestCase {
    @MainActor
    func testHoverCountMatchesPrioritizedRequests() throws {
        let source = URL(fileURLWithPath: "/tmp/inkpeg-intake-count-" + UUID().uuidString + ".txt")
        try Data("synthetic file".utf8).write(to: source)
        let board = NSPasteboard(name: .init("InkpegCountAudit-" + UUID().uuidString))
        let file = NSPasteboardItem(); file.setString(source.absoluteString, forType: .fileURL)
        let text = NSPasteboardItem(); text.setString("separate text item", forType: .string)
        XCTAssertTrue(board.writeObjects([file, text]))
        let target = LineDropTarget(); var hoverCount = 0, receivedCount = 0
        target.onHover = { hoverCount = $0 }; target.onReceive = { receivedCount = $0.count; return true }
        XCTAssertEqual(target.updateHover(from: board), .copy)
        let displayedCount = hoverCount
        XCTAssertTrue(target.receive(from: board))
        XCTAssertEqual(displayedCount, receivedCount, "The drop hint must count representations that will actually be imported")
    }


    @MainActor
    func testCaptureSettingsReflectCompletedPause() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-intake-capture-" + UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = MaterialStore(root: root.appendingPathComponent("owned"))
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let setting = CaptureFolderSetting(bookmark: bookmark, lastKnownPath: folder.path, enabled: true)
        let snapshot = try await store.apply(.setCaptureFolder(setting))
        let coordinator = CaptureFolderCoordinator(store: store)
        defer { coordinator.onStatusChanged = {}; coordinator.stop() }
        coordinator.onError = { error in XCTFail("Unexpected coordinator error code " + String((error as NSError).code)) }
        coordinator.restore(snapshot)
        XCTAssertTrue(coordinator.isEnabled)
        let service = ClipboardImportService(gateway: AdapterAuditClipboard(), store: store)
        let model = IntakeSettingsModel(service: service, capture: coordinator)
        XCTAssertTrue(model.captureEnabled)
        let paused = expectation(description: "Pause completes")
        coordinator.onStatusChanged = {
            model.refresh()
            if coordinator.status == .capturePaused { paused.fulfill() }
        }
        model.toggleCapture()
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(model.captureEnabled, "The settings toggle must show the completed pause")
    }

    @MainActor
    func testAcceptedDropMustNotBeLostWhenAutomaticPollStartsBeforeItsTask() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-intake-drop-race-" + UUID().uuidString, isDirectory: true)
        let store = MaterialStore(root: root)
        try await store.setClipboardPreferences(ClipboardPreference(enabled: true, includeExisting: false))
        let board = AdapterAuditClipboard()
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        let dropBoard = NSPasteboard(name: .init("InkpegAdapterAudit-" + UUID().uuidString))
        let item = NSPasteboardItem(); item.setString("explicitly dropped text", forType: .string)
        XCTAssertTrue(dropBoard.writeObjects([item]))
        let target = LineDropTarget()
        target.canReceive = { service.canReceiveManual }
        let imported = expectation(description: "Accepted drop is saved")
        service.onSnapshot = { snapshot in
            if snapshot.materials.contains(where: { $0.source.origin == .drop }) { imported.fulfill() }
        }
        target.onReceive = { service.enqueueManual($0) }
        board.changeCount += 1
        XCTAssertTrue(target.receive(from: dropBoard), "The production adapter acknowledges this drop")
        await service.poll()
        await fulfillment(of: [imported], timeout: 2)
        let saved = try await store.load()
        XCTAssertTrue(saved.materials.contains { $0.source.origin == .drop }, "An acknowledged drop must be saved or retained pending")
    }
}

@MainActor private final class AdapterAuditClipboard: ClipboardGateway {
    var changeCount = 1
    func readSnapshot() throws -> ClipboardContents {
        ClipboardContents(revision: changeCount, requests: [.text("automatic clipboard text", SourceRecord(origin: .clipboard))])
    }
}
