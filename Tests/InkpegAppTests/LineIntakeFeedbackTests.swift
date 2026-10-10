import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class LineIntakeFeedbackTests: XCTestCase {
    @MainActor
    func testExplicitPasteReportsSavedOnlyAfterCommitAndEmptyOrDuplicateNeverReportsSuccess() async throws {
        let (line, service, controller, board) = try await fixture()
        board.setString("合成反馈文字", forType: .string)
        let entered = expectation(description: "Committed import callback reached")
        var release: CheckedContinuation<Void, Never>?
        service.onImported = { _, _ in
            XCTAssertEqual(line.inputFeedback, L(.inputReceiving), "Reservation is not success")
            entered.fulfill()
            await withCheckedContinuation { release = $0 }
            controller.imported()
        }
        let paste = Task { await controller.paste() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(line.inputFeedback, L(.inputReceiving))
        release?.resume(); await paste.value
        XCTAssertEqual(line.inputFeedback, L(.inputSaved))
        let saved = try await line.store.load(); XCTAssertEqual(saved.materials.count, 1)
        service.onImported = { _, _ in XCTFail("Duplicate must not claim a new saved card") }
        await controller.paste()
        XCTAssertEqual(line.inputFeedback, L(.inputNothingNew))
        board.clearContents(); await controller.paste()
        XCTAssertEqual(line.inputFeedback, L(.inputNothingNew))
        let unchanged = try await line.store.load(); XCTAssertEqual(unchanged.materials.count, 1)
    }

    @MainActor
    func testAcceptedDropReportsReceivingUntilCommittedThenSaved() async throws {
        let (line, service, controller, _) = try await fixture()
        let finished = expectation(description: "Acknowledged drop completes")
        service.onStateChanged = { controller.refresh(); if line.inputFeedback == L(.inputSaved) { finished.fulfill() } }
        XCTAssertTrue(controller.enqueue([.text("合成拖入反馈", SourceRecord(origin: .drop))]))
        XCTAssertEqual(line.inputFeedback, L(.inputReceiving))
        XCTAssertFalse(controller.enqueue([.text("不可挤入第二任务", SourceRecord(origin: .drop))]))
        await fulfillment(of: [finished], timeout: 2)
        let saved = try await line.store.load(); XCTAssertEqual(saved.materials.count, 1)
        XCTAssertEqual(line.inputFeedback, L(.inputSaved))
    }

    @MainActor
    func testPendingPinnedCapacityAndRejectedContentStayVisibleInsteadOfClaimingSuccess() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-feedback-pending-" + UUID().uuidString)
        let seedStore = MaterialStore(root: root)
        let result = try await seedStore.importMaterial(.text("合成固定卡", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = result.snapshot; seed.materials[0].pinned = true
        try await seedStore.setClipboardPreferences(ClipboardPreference(enabled: false))
        try JSONEncoder().encode(seed).write(to: root.appendingPathComponent("state.json"), options: .atomic)
        let line = Line(store: MaterialStore(root: root)); try await line.load()
        let board = NSPasteboard(name: .init("InkpegFeedbackPending-" + UUID().uuidString))
        board.setString("合成等待文字", forType: .string)
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: line.store, capacity: { 1 })
        let controller = LineIntakeController(line: line, service: service)
        service.onStateChanged = { controller.refresh() }; service.onImported = { _, _ in controller.imported() }
        await service.start(); await controller.paste()
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertEqual(line.inputFeedback, L(.clipboardPending))
        let retained = try await line.store.load(); XCTAssertEqual(retained.materials.count, 1); XCTAssertTrue(retained.materials[0].pinned)
        XCTAssertTrue(service.discardPending())
        board.setString(String(repeating: "x", count: ClipboardLimits.textBytes + 1), forType: .string)
        await controller.paste()
        XCTAssertEqual(line.inputFeedback, L(.clipboardRejected))
        XCTAssertNotEqual(line.inputFeedback, L(.inputSaved))
    }

    @MainActor
    func testPendingFeedbackChangesToSavedAfterAnExplicitRetry() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-feedback-retry-" + UUID().uuidString)
        let seedStore = MaterialStore(root: root)
        let seedResult = try await seedStore.importMaterial(.text("合成固定卡", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = seedResult.snapshot; seed.materials[0].pinned = true
        try await seedStore.setClipboardPreferences(ClipboardPreference(enabled: false))
        try JSONEncoder().encode(seed).write(to: root.appendingPathComponent("state.json"), options: .atomic)
        let line = Line(store: MaterialStore(root: root)); try await line.load()
        let board = NSPasteboard(name: .init("InkpegFeedbackRetry-" + UUID().uuidString))
        board.setString("合成待处理材料", forType: .string)
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: line.store, capacity: { 1 })
        let controller = LineIntakeController(line: line, service: service)
        service.onStateChanged = { controller.refresh() }; service.onImported = { _, _ in controller.imported() }
        await service.start(); await controller.paste()
        XCTAssertEqual(line.inputFeedback, L(.clipboardPending))
        _ = try await line.store.apply(.takeDown(seed.materials[0].id))
        await service.retryPending()
        XCTAssertEqual(line.inputFeedback, L(.inputSaved))
        let saved = try await line.store.load(); XCTAssertEqual(saved.materials.count, 2)
        XCTAssertEqual(saved.materials.first?.status, .takenDown)
        XCTAssertEqual(service.pendingCount, 0)
    }

    @MainActor private func fixture() async throws -> (Line, ClipboardImportService, LineIntakeController, NSPasteboard) {
        let line = Line(store: MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-feedback-" + UUID().uuidString)))
        try await line.load()
        let board = NSPasteboard(name: .init("InkpegFeedback-" + UUID().uuidString))
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: line.store)
        let controller = LineIntakeController(line: line, service: service)
        service.onSnapshot = { await line.render($0) }
        service.onImported = { _, _ in controller.imported() }
        service.onStateChanged = { controller.refresh() }
        await service.start()
        XCTAssertFalse(service.isEnabled, "Default remains manual")
        return (line, service, controller, board)
    }
}
