import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class M1ClosureBoundaryAuditTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func fixture() async throws -> (MaterialStore, Line, MaterialDetailController, [UUID]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-m1-closure-audit-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        var ids = [UUID]()
        for text in ["A 独立材料", "B 独立材料"] {
            let result = try await store.importMaterial(.text(text, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            await line.render(result.snapshot)
            ids.append(try XCTUnwrap(result.snapshot.materials.last?.id))
        }
        let board = NSPasteboard(name: .init("InkpegM1Closure-" + UUID().uuidString))
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: board), editor: TextEditorController(line: line))
        return (store, line, detail, ids)
    }
    @MainActor func testNativeSaveTitleButtonRetainsUnsavedSourceFieldsAndWindow() async throws {
        let (store, _, detail, ids) = try await fixture()
        try await detail.open(ids[0], present: false)
        let window = try XCTUnwrap(detail.window)
        defer { detail.window?.close() }
        let views = descendants(try XCTUnwrap(window.contentView))
        let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        XCTAssertEqual(fields.count, 5)
        fields[0].stringValue = "保存的标题"
        fields[1].stringValue = "未保存来源名称"
        fields[2].stringValue = "https://example.invalid/unsaved"
        fields[4].stringValue = "未保存位置"
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L(.saveTitle) })
        button.performClick(nil)
        var saved = false
        for _ in 0..<80 {
            let snapshot = try await store.load()
            if snapshot.materials.first(where: { $0.id == ids[0] })?.title == "保存的标题" { saved = true; break }
            await Task.yield()
        }
        XCTAssertTrue(saved, "A real native button must invoke the title-save operation")
        XCTAssertTrue(detail.window === window)
        XCTAssertEqual(fields[1].stringValue, "未保存来源名称")
        XCTAssertEqual(fields[2].stringValue, "https://example.invalid/unsaved")
        XCTAssertEqual(fields[4].stringValue, "未保存位置")
    }
    @MainActor func testSourceSaveCompletionCannotReplaceOtherMaterialsSourceSummary() async throws {
        let (_, line, detail, ids) = try await fixture()
        try await detail.open(ids[0], present: false)
        defer { detail.window?.close() }
        let fields = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        fields[1].stringValue = "A 来源保存完成"
        let saving = Task { @MainActor in try await detail.saveSource() }
        let switching = Task { @MainActor in try await detail.open(ids[1], present: false) }
        try await saving.value
        try await switching.value
        let visible = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }
        let activeFields = visible.filter { $0.isEditable }
        XCTAssertEqual(activeFields[0].stringValue, "B 独立材料")
        XCTAssertEqual(activeFields[1].stringValue, "")
        XCTAssertFalse(visible.contains { !$0.isEditable && $0.stringValue.contains("A 来源保存完成") }, "A save finishing late must not overwrite B's shared source summary")
        XCTAssertNil(line.snapshot.materials.first(where: { $0.id == ids[1] })?.source.manualTitle)
    }
    @MainActor func testConcurrentOpenKeepsFormAndPreviewBoundToSameMaterial() async throws {
        let (store, line, detail, ids) = try await fixture()
        let draft = try await store.createDerivedVersion(of: ids[0], kind: .textEdit)
        try await store.writeEditingResult(draft, data: Data("A 编辑副本".utf8))
        await line.render(try await store.finishEditing(draft, result: .save(draft.workingURL)))
        defer { detail.window?.close() }
        let first = Task { @MainActor in try await detail.open(ids[0], present: false) }
        let second = Task { @MainActor in try await detail.open(ids[1], present: false) }
        try await first.value
        try await second.value
        let views = descendants(try XCTUnwrap(detail.window?.contentView))
        let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        XCTAssertEqual(fields.count, 5, "Concurrent opens must keep all shared form controls in the displayed window")
        guard let title = fields.first else { return }
        let preview = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(String(preview.string.prefix(1)), String(title.stringValue.prefix(1)), "Concurrent opens must not combine one record's title/source with another record's preview")
    }
}
