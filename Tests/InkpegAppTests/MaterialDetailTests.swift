import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class MaterialDetailTests: XCTestCase {
    @MainActor func testDetailHasUsableSourceFieldsAndPreviewInIndependentWindow() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-detail-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.text("合成中文摘录 \nEnglish text", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot); let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let board = NSPasteboard(name: .init("InkpegDetail-" + UUID().uuidString))
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: board), editor: TextEditorController(line: line))
        try await detail.open(id, present: false)
        let window = try XCTUnwrap(detail.window), content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(window.canBecomeKey); content.layoutSubtreeIfNeeded()
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let fields = descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 5)
        for field in fields { XCTAssertGreaterThan(field.frame.width, 150); XCTAssertGreaterThan(field.frame.height, 12) }
        let preview = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(preview.string, "合成中文摘录 \nEnglish text"); XCTAssertFalse(preview.isEditable)
        XCTAssertGreaterThan(preview.enclosingScrollView?.frame.height ?? 0, 100)
        window.close()
    }
}
