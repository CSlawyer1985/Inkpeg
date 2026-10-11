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


import InkpegCore

extension LinePanelAccessibilityTests {
    @MainActor
    func testHostingViewOffersExplicitKeyboardResponder() {
        let line = Line(store: MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-keyboard-test-" + UUID().uuidString)))
        XCTAssertTrue(LineHostingView(line: line).acceptsFirstResponder)
    }
}


extension LinePanelAccessibilityTests {
    @MainActor
    func testExplicitBrowsingMovesAcrossVirtualizedShelfAndEscapeRestoresOnce() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-keyboard-test-" + UUID().uuidString))
        let line = Line(store: store)
        for index in 0..<50 { _ = try await store.importMaterial(.text("Keyboard fixture \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max) }
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        defer { panel.close() }
        panel.orderFrontRegardless()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertNil(line.keyboardID)
        var restored = 0, copied: UUID?
        line.onCopy = { copied = $0 }
        panel.beginKeyboardBrowsing(restoringFocus: { restored += 1 })
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.firstResponder === host)
        XCTAssertEqual(line.keyboardID, line.items.first?.id)
        func key(_ code: UInt16) throws -> NSEvent { try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)) }
        for _ in 0..<60 { host.keyDown(with: try key(124)) }
        XCTAssertEqual(line.keyboardID, line.items.last?.id)
        XCTAssertGreaterThan(line.scrollOffset, 0)
        XCTAssertLessThanOrEqual(line.scrollOffset, line.maximumScrollOffset)
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        let selectedCard = try XCTUnwrap(host.cardViews.first { $0.materialID == line.keyboardID })
        XCTAssertTrue(selectedCard.isAccessibilityFocused())
        host.keyDown(with: try key(36))
        XCTAssertEqual(copied, line.items.last?.id)
        host.keyDown(with: try key(123))
        XCTAssertEqual(line.keyboardID, line.items[48].id)
        host.keyDown(with: try key(53))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertNil(line.keyboardID)
        XCTAssertEqual(restored, 1)
        panel.endKeyboardBrowsing(); XCTAssertEqual(restored, 1)
    }

    @MainActor
    func testPrivacySynchronouslyClearsRetainedNativeAccessibilityContent() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-keyboard-test-" + UUID().uuidString)), line = Line(store: store)
        _ = try await store.importMaterial(.text("Synthetic private title", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max)
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000)
        let retained = try XCTUnwrap(host.cardViews.first)
        XCTAssertTrue(retained.isAccessibilityElement())
        XCTAssertTrue(try XCTUnwrap(retained.accessibilityLabel()).contains("Synthetic private title"))
        var restored = 0
        panel.beginKeyboardBrowsing(restoringFocus: { restored += 1 })
        var hidden = line.snapshot; hidden.privacyHidden = true
        await line.render(hidden)
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(retained.isAccessibilityElement())
        XCTAssertNil(retained.accessibilityLabel())
        XCTAssertNil(retained.accessibilityHelp())
        XCTAssertFalse(retained.accessibilityPerformPress())
        XCTAssertFalse(retained.accessibilityPerformShowMenu())
        XCTAssertTrue(try XCTUnwrap(host.accessibilityChildren()).isEmpty)
        panel.beginKeyboardBrowsing(restoringFocus: { XCTFail("Hidden shelf must not start keyboard mode") })
        XCTAssertFalse(panel.isKeyboardBrowsing)
    }
}

extension LinePanelAccessibilityTests {
    @MainActor
    func testHostEscapeKeyCancelsSuspendedDragBeforeRestoringFocus() async throws {
        try await checkHostCancelsSuspendedDrag(usingCancelOperation: false)
    }

    @MainActor
    func testHostCancelOperationCancelsSuspendedDragBeforeRestoringFocus() async throws {
        try await checkHostCancelsSuspendedDrag(usingCancelOperation: true)
    }

    @MainActor
    private func checkHostCancelsSuspendedDrag(usingCancelOperation: Bool) async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/host-escape-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        _ = try await store.importMaterial(.text("Synthetic pending drag", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max)
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let item = try XCTUnwrap(line.items.first)
        // Prepare real export data before suspension so a late provider can
        // deliberately return even after its task receives cancellation.
        let provider = try await CopyOutProvider(store: store, id: item.id, versionID: item.versionID,
            suffix: "txt", canExport: { !line.snapshot.privacyHidden }).prepareProvider(exportRoot: root)
        var pending: CheckedContinuation<Void, Never>?
        let preparing = expectation(description: "production gesture awaits provider")
        let returned = expectation(description: "late provider returned")
        var wasCancelled = false
        line.onPrepareDrag = { card in
            XCTAssertEqual(card.id, item.id)
            await withCheckedContinuation { pending = $0; preparing.fulfill() }
            wasCancelled = Task.isCancelled
            returned.fulfill()
            return provider
        }
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000)
        let source = try XCTUnwrap(host.cardViews.first { $0.materialID == item.id })
        defer { source.cancelDragPreparation(); source.finishDrag() }
        var restored = 0, starts = 0, errors = 0
        line.onError = { _ in errors += 1 }
        source.beginSession = { _, _, _ in starts += 1 }
        panel.beginKeyboardBrowsing(restoringFocus: {
            restored += 1
            XCTAssertNil(line.pressedID, "Cancel the press before restoring the previous application")
            XCTAssertNil(line.keyboardID)
        })
        XCTAssertTrue(panel.firstResponder === host)
        XCTAssertEqual(line.keyboardID, item.id)
        func mouse(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            let point = source.convert(NSPoint(x: source.bounds.midX + offset, y: source.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        source.mouseDown(with: try mouse(.leftMouseDown))
        source.mouseDragged(with: try mouse(.leftMouseDragged, offset: 20))
        await fulfillment(of: [preparing], timeout: 2)
        XCTAssertEqual(line.pressedID, item.id)
        XCTAssertNotNil(line.cancelPress)
        XCTAssertTrue(panel.firstResponder === host, "The keyboard host, not the source card, receives Escape")
        let responder = try XCTUnwrap(panel.firstResponder)
        if usingCancelOperation { responder.cancelOperation(nil) }
        else {
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            responder.keyDown(with: escape)
        }
        XCTAssertNil(line.pressedID)
        XCTAssertNil(line.cancelPress)
        XCTAssertNil(line.keyboardID)
        XCTAssertFalse(panel.isKeyboardBrowsing)
        XCTAssertEqual(restored, 1)
        pending?.resume(); pending = nil
        await fulfillment(of: [returned], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(wasCancelled, "The suspended provider task must receive cancellation")
        XCTAssertEqual(starts, 0, "A late provider must never start a native drag after Escape")
        XCTAssertEqual(errors, 0)
        XCTAssertNil(line.pressedID)
        XCTAssertNil(line.draggingID)
        XCTAssertFalse(GrabView.isDragging)
        responder.cancelOperation(nil)
        XCTAssertEqual(restored, 1, "Repeated cancellation must not restore focus twice")
    }
}
