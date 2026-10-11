import XCTest
import AppKit
import SwiftUI
import InkpegCore
@testable import Inkpeg

final class NoteCardRoutingTests: XCTestCase {
    @MainActor func testAuthoredCardClickEditsAndImportedCardStillCopies() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-card-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let draft = try await store.createNoteDraft(); _ = try await store.updateNoteDraft(draft.id, text: "合成原创便笺")
        _ = try await store.publishNoteDraft(draft.id)
        let imported = try await store.importMaterial(.text("合成导入摘录", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let excerpt = try XCTUnwrap(imported.snapshot.materials.first { $0.source.origin == .clipboard })
        await line.render(imported.snapshot); line.revealed = true
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        defer { panel.close() }
        panel.setFrame(NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 750_000_000); host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let cards = descendants(host).compactMap { $0 as? GrabView }
        XCTAssertEqual(cards.count, 2)
        let note = try XCTUnwrap(cards.first { $0.materialID == draft.materialID })
        let copy = try XCTUnwrap(cards.first { $0.materialID == excerpt.id })
        XCTAssertEqual(note.accessibilityLabel(), L(.inputText) + " · 合成原创便笺 · " + String(format: L(.shelfPosition), 1, 2))
        XCTAssertEqual(copy.accessibilityLabel(), L(.inputText) + " · 合成导入摘录 · " + String(format: L(.shelfPosition), 2, 2))
        XCTAssertEqual(note.accessibilityHelp(), L(.noteContinue) + " · " + L(.shelfKeyboardHelp))
        XCTAssertEqual(copy.accessibilityHelp(), L(.copy) + " · " + L(.shelfKeyboardHelp))
        var edited = [UUID](), copied = [UUID]()
        line.onOpenNote = { edited.append($0) }; line.onCopy = { copied.append($0) }
        let point = note.convert(NSPoint(x: note.bounds.midX, y: note.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        note.mouseDown(with: down); note.mouseUp(with: up)
        XCTAssertEqual(edited, [draft.materialID], "Note clicks should open the existing card immediately")
        XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(copy.accessibilityPerformPress()); XCTAssertEqual(copied, [excerpt.id])
        XCTAssertEqual(line.snapshot.materials.first { $0.id == excerpt.id }, excerpt)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.isVisible)
    }
}
