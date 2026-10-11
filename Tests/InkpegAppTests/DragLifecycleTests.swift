import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class DragLifecycleTests: XCTestCase {
    @MainActor
    func testCancelledPreparationCannotClearTheNextGestureTask() async throws {
        let view = GrabView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var waits = [CheckedContinuation<NSFilePromiseProvider, Error>]()
        var calls = 0
        var pressed = false
        view.onPressChange = { pressed = $0 }
        let first = expectation(description: "first drag preparing"), second = expectation(description: "second drag preparing")
        view.prepareDrag = {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                waits.append(continuation)
                if calls == 1 { first.fulfill() } else if calls == 2 { second.fulfill() }
            }
        }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 50)); view.mouseDragged(with: try mouse(.leftMouseDragged, x: 70))
        await fulfillment(of: [first], timeout: 2)
        view.mouseUp(with: try mouse(.leftMouseUp, x: 70))
        view.mouseDown(with: try mouse(.leftMouseDown, x: 50)); view.mouseDragged(with: try mouse(.leftMouseDragged, x: 70))
        await fulfillment(of: [second], timeout: 2)
        XCTAssertTrue(pressed, "The next preparing gesture keeps its host reservation")
        waits[0].resume(throwing: CancellationError())
        for _ in 0..<10 { await Task.yield() }
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 75))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(pressed, "A cancelled older preparation must not clear the new press")
        XCTAssertEqual(calls, 2, "The old task must not allow a third preparation in the second gesture")
        view.mouseUp(with: try mouse(.leftMouseUp, x: 75))
        XCTAssertFalse(pressed)
        for continuation in waits.dropFirst() { continuation.resume(throwing: CancellationError()) }
    }

    @MainActor
    func testPrivacyChangeDuringPromiseCompletionDoesNotReportSuccess() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-drag-lifecycle-" + UUID().uuidString), store = MaterialStore(root: root)
        let imported = try await store.importMaterial(.text("synthetic", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        var checks = 0
        let provider = CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "txt", canExport: { checks += 1; return checks == 1 }).provider()
        let delegate = try XCTUnwrap(provider.delegate), destination = URL(fileURLWithPath: "/tmp/inkpeg-received-" + UUID().uuidString + ".txt")
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(error as? StoreError, .invalidSource)
        let unchanged = try await store.load(); XCTAssertEqual(unchanged, imported.snapshot)
    }
}
