import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class TextEditorTests: XCTestCase {
    @MainActor func testClosingSessionClearsUndoBeforeOpeningOrResumingAnother() async throws {
        for saves in [false, true] {
            let (store, line, editor, firstID) = try await undoFixture()
            let second = try await store.importMaterial(.text("B 原文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            await line.render(second.snapshot)
            let secondID = try XCTUnwrap(second.snapshot.materials.last?.id)
            XCTAssertNotEqual(firstID, secondID)
            let secondDraft = try await store.createDerivedVersion(of: secondID, kind: .textEdit)
            try await store.writeEditingResult(secondDraft, data: Data("B 恢复草稿".utf8))
            try await editor.open(firstID, present: false)
            editor.textView.insertText("A 编辑", replacementRange: NSRange(location: 0, length: 0))
            let previousUndo = try XCTUnwrap(editor.textView.undoManager)
            XCTAssertTrue(previousUndo.canUndo)
            if saves { try await editor.save() } else { try await editor.cancel() }
            XCTAssertFalse(previousUndo.canUndo, "A closed session must release its undo history")
            if saves { try await editor.open(secondID, present: false) } else { try await editor.resume(secondDraft, present: false) }
            let baseline = saves ? "B 原文" : "B 恢复草稿"
            XCTAssertEqual(editor.text, baseline)
            let undo = try XCTUnwrap(editor.textView.undoManager)
            XCTAssertFalse(undo.canUndo)
            performNativeTextUndo(undo)
            XCTAssertEqual(editor.textView.string, baseline)
            editor.textView.insertText("B 编辑", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(undo.canUndo)
            performNativeTextUndo(undo); XCTAssertEqual(editor.text, baseline)
            performNativeTextUndo(undo, redo: true); XCTAssertEqual(editor.text, "B 编辑" + baseline)
            try await editor.cancel()
        }
    }

    @MainActor func testFailedTextSaveKeepsSessionEditableAndNativeUndoHistory() async throws {
        for fault in ["working.txt", "state.json"] {
            let files = TextSaveFaultFiles()
            let (store, _, editor, id) = try await undoFixture(files: files)
            try await editor.open(id, present: false)
            let session = try XCTUnwrap(editor.session)
            editor.textView.insertText("待保存", replacementRange: NSRange(location: 0, length: 0))
            files.failingName = fault
            do { try await editor.save(); XCTFail("Injected save failure must surface") }
            catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
            XCTAssertEqual(editor.session, session)
            XCTAssertNotNil(editor.window); XCTAssertTrue(editor.textView.isEditable)
            XCTAssertEqual(editor.text, "待保存原文")
            let undo = try XCTUnwrap(editor.textView.undoManager)
            XCTAssertTrue(undo.canUndo)
            performNativeTextUndo(undo); XCTAssertEqual(editor.text, "原文")
            performNativeTextUndo(undo, redo: true); XCTAssertEqual(editor.text, "待保存原文")
            editor.textView.breakUndoCoalescing()
            editor.textView.insertText("继续", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(editor.text, "继续待保存原文")
            performNativeTextUndo(undo); XCTAssertEqual(editor.text, "待保存原文")
            performNativeTextUndo(undo, redo: true); XCTAssertEqual(editor.text, "继续待保存原文")
            files.failingName = nil
            try await editor.cancel()
            XCTAssertEqual(try String(contentsOf: session.workingURL), "继续待保存原文")
            let original = try await store.payloadURL(of: id, versionID: session.baseVersionID)
            XCTAssertEqual(try String(contentsOf: original), "原文")
        }
    }

    @MainActor func testMarkedTextStillBlocksSaveAndCancelWithoutDiscardingComposition() async throws {
        let (store, _, editor, id) = try await undoFixture()
        try await editor.open(id, present: false)
        let session = try XCTUnwrap(editor.session)
        editor.textView.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let composing = editor.textView.string
        for saves in [true, false] {
            do {
                if saves { try await editor.save() } else { try await editor.cancel() }
                XCTFail("Native composition must finish before ending the session")
            } catch { XCTAssertEqual(error as? StoreError, .operationInProgress) }
            XCTAssertEqual(editor.session, session)
            XCTAssertTrue(editor.textView.hasMarkedText()); XCTAssertTrue(editor.textView.isEditable)
            XCTAssertEqual(editor.textView.string, composing)
            XCTAssertEqual(try String(contentsOf: session.workingURL), "原文")
        }
        editor.textView.unmarkText()
        editor.textView.insertText("已提交中文", replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        try await editor.save()
        let payload = try await store.payloadURL(of: id)
        XCTAssertEqual(try String(contentsOf: payload), "已提交中文")
    }

    @MainActor private func undoFixture(files: any FileOperations = SystemFileOperations()) async throws -> (MaterialStore, Line, TextEditorController, UUID) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-text-native-" + UUID().uuidString)
        let store = MaterialStore(root: root, files: files), line = Line(store: store)
        let imported = try await store.importMaterial(.text("原文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        return (store, line, TextEditorController(line: line), try XCTUnwrap(imported.snapshot.materials.first?.id))
    }

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

private final class TextSaveFaultFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    var failingName: String? {
        get { lock.lock(); defer { lock.unlock() }; return failure }
        set { lock.lock(); defer { lock.unlock() }; failure = newValue }
    }
    private let base = SystemFileOperations()
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == failingName { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
