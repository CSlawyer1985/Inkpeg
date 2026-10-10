import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class TextEditorTests: XCTestCase {
    @MainActor func testEditedTextKeepsOriginalExcerptAndSource() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-text-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let source = SourceRecord(origin: .clipboard, manualTitle: "合成来源", locator: .printedPage("八"), isManuallyRegistered: true)
        let imported = try await store.importMaterial(.text("原文 中文 English", source), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot); let original = try XCTUnwrap(imported.snapshot.materials.first)
        let editor = TextEditorController(line: line)
        try await editor.open(original.id, present: false)
        XCTAssertTrue(try XCTUnwrap(editor.window).canBecomeKey)
        XCTAssertFalse(LinePanel(content: NSView()).canBecomeKey)
        XCTAssertEqual(editor.text, "原文 中文 English")
        editor.text = "编辑副本，中文输入保留。"
        try await editor.save()
        let updated = try XCTUnwrap(line.snapshot.materials.first)
        XCTAssertEqual(updated.versions.count, 2)
        XCTAssertEqual(updated.activeVersion?.kind, .textEdit)
        XCTAssertEqual(updated.source, source)
        let originalURL = try await store.payloadURL(of: original.id, versionID: original.originalVersionID)
        XCTAssertEqual(try String(contentsOf: originalURL), "原文 中文 English")
        let currentURL = try await store.payloadURL(of: original.id)
        XCTAssertEqual(try String(contentsOf: currentURL), "编辑副本，中文输入保留。")
        XCTAssertFalse(editor.isEditing)
    }
    @MainActor func testCancelRetainsDraftAndResumeDoesNotChangeOriginal() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-text-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let result = try await store.importMaterial(.text("原文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(result.snapshot); let id = try XCTUnwrap(result.snapshot.materials.first?.id)
        let editor = TextEditorController(line: line); try await editor.open(id, present: false)
        editor.text = "未提交中文草稿"; try await editor.cancel()
        XCTAssertEqual(line.snapshot, result.snapshot)
        let drafts = try await store.pendingEditSessions(); XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first), resumed = TextEditorController(line: line)
        try await resumed.resume(draft, present: false); XCTAssertEqual(resumed.text, "未提交中文草稿")
        try await resumed.cancel()
    }
    @MainActor func testOpenEditorBlocksQuitAndHiddenEditorRetainsDraft() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-text-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let result = try await store.importMaterial(.text("合成原文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(result.snapshot); let id = try XCTUnwrap(result.snapshot.materials.first?.id)
        let editor = TextEditorController(line: line); try await editor.open(id, present: false); editor.text = "未保存合成草稿"
        let app = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root))
        XCTAssertEqual(app.requestTermination(markup: Markup(), clipboard: nil, textEditor: editor, respond: { _ in .alertFirstButtonReturn }), .terminateCancel)
        editor.setHidden(true); XCTAssertFalse(editor.textView.isEditable); XCTAssertEqual(editor.text, "未保存合成草稿")
        try await editor.cancel(); XCTAssertFalse(editor.isEditing)
    }
}
