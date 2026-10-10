import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class NoteEditorTests: XCTestCase {
    @MainActor func testRevertingFailedInputToDurableBodyDoesNotTrapDismissal() async throws {
        let files = NoteSaveFaultFiles()
        let (_, store, _, editor) = try await fixture(files: files)
        try await editor.openNew(present: false); files.failDraftWrites = true
        type("未落盘文字", in: editor)
        do { try await editor.flushAutosave(); XCTFail("Injected write must fail") } catch {}
        type("", in: editor)
        try await editor.dismiss()
        XCTAssertFalse(editor.hasUnsavedInput)
        let pending = try await store.pendingNoteDrafts()
        XCTAssertEqual(pending.first?.id, editor.draft?.id); XCTAssertEqual(pending.first?.text, "")
        editor.window?.close()
    }
    @MainActor func testHideDuringPublishCannotBeUndoneByItsOlderSnapshot() async throws {
        let files = NoteSaveFaultFiles()
        let (_, store, line, editor) = try await fixture(files: files)
        try await editor.openNew(present: false); type("合成发布中敏感正文", in: editor)
        let semaphore = DispatchSemaphore(value: 0)
        files.stageWriteHandler = {
            DispatchQueue.main.async {
                Task { @MainActor in
                    var hidden = line.snapshot; hidden.privacyHidden = true
                    await line.render(hidden); semaphore.signal()
                }
            }
            if semaphore.wait(timeout: .now() + 3) == .timedOut { throw StoreError.operationInProgress }
        }
        try await editor.hang()
        XCTAssertTrue(line.snapshot.privacyHidden, "Publishing must preserve a later hide request")
        let saved = try await store.load(); XCTAssertEqual(saved.materials.count, 1)
    }
    @MainActor func testCommandReturnAlsoWorksWithCapsLockAndDoesNotInterpretText() throws {
        let view = NoteTextView(); var hangs = 0
        view.onHang = { hangs += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: event)
        XCTAssertEqual(hangs, 1); XCTAssertEqual(view.string, "")
    }
    @MainActor func testQuitCannotDiscardFailedNoteSave() async throws {
        let files = NoteSaveFaultFiles()
        let (root, _, _, editor) = try await fixture(files: files)
        try await editor.openNew(present: false); files.failDraftWrites = true
        type("退出时不能丢的正文", in: editor)
        do { try await editor.flushAutosave(); XCTFail("Injected note write must fail") } catch {}
        let app = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root)); var prompts = 0
        XCTAssertEqual(app.requestTermination(markup: Markup(), clipboard: nil, noteEditor: editor, respond: { _ in prompts += 1; return .alertFirstButtonReturn }), .terminateCancel)
        XCTAssertEqual(prompts, 1)
        files.failDraftWrites = false; try await editor.flushAutosave()
        XCTAssertEqual(app.requestTermination(markup: Markup(), clipboard: nil, noteEditor: editor, respond: { _ in .alertFirstButtonReturn }), .terminateNow)
        editor.window?.close()
    }
    @MainActor private func fixture(files: any FileOperations = SystemFileOperations()) async throws -> (URL, MaterialStore, Line, NoteEditorController) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-ui-" + UUID().uuidString)
        let store = MaterialStore(root: root, files: files), line = Line(store: store)
        try await line.load()
        return (root, store, line, NoteEditorController(line: line))
    }
    @MainActor private func type(_ text: String, in editor: NoteEditorController) {
        editor.textView.string = text
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
    }
    @MainActor func testDraftAutosavesWithoutHangingAndCanResumeAfterDismissal() async throws {
        let (_, store, line, editor) = try await fixture()
        try await editor.openNew(present: false)
        let draftID = try XCTUnwrap(editor.draft?.id)
        XCTAssertTrue(try XCTUnwrap(editor.window).canBecomeKey)
        type("标题第一行\n正文中文，尚未写完", in: editor)
        try await editor.flushAutosave(); try await editor.dismiss()
        let pending = try await store.pendingNoteDrafts()
        XCTAssertEqual(pending.first?.text, "标题第一行\n正文中文，尚未写完")
        XCTAssertTrue(line.items.isEmpty)
        let resumed = NoteEditorController(line: line)
        try await resumed.openNew(present: false)
        XCTAssertEqual(resumed.draft?.id, draftID)
        XCTAssertEqual(resumed.textView.string, "标题第一行\n正文中文，尚未写完")
        resumed.window?.close(); editor.window?.close()
    }
    @MainActor func testConcurrentNewClicksReserveOneDraftAndWindow() async throws {
        let (_, store, _, editor) = try await fixture()
        let a = Task { @MainActor () -> Bool in do { try await editor.openNew(present: false); return true } catch { return false } }
        let b = Task { @MainActor () -> Bool in do { try await editor.openNew(present: false); return true } catch { return false } }
        let results = await [a.value, b.value]
        XCTAssertTrue(results.contains(true))
        let id = try XCTUnwrap(editor.draft?.id), window = try XCTUnwrap(editor.window)
        type("连续点击不覆盖正文", in: editor); try await editor.flushAutosave()
        try await editor.openNew(present: false)
        XCTAssertEqual(editor.draft?.id, id); XCTAssertTrue(editor.window === window)
        let pending = try await store.pendingNoteDrafts(); XCTAssertEqual(pending.count, 1)
        window.close()
    }
    @MainActor func testHangRejectsMarkedTextWithoutTruncationThenUpdatesSameCard() async throws {
        let (_, store, line, editor) = try await fixture()
        try await editor.openNew(present: false)
        editor.textView.setMarkedText("中文输入候选", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 0, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        let composing = editor.textView.string
        try await editor.flushAutosave()
        do { try await editor.hang(); XCTFail("Composition must finish before hanging") }
        catch { XCTAssertEqual(error as? StoreError, .operationInProgress) }
        XCTAssertTrue(editor.textView.hasMarkedText()); XCTAssertEqual(editor.textView.string, composing)
        let snapshot = try await store.load(); XCTAssertTrue(snapshot.materials.isEmpty)
        editor.textView.unmarkText(); type("已完成记事\n完整正文", in: editor)
        try await editor.hang()
        let note = try XCTUnwrap(line.snapshot.materials.first)
        try await editor.open(note.id, present: false); type("再次编辑同一张", in: editor); try await editor.hang()
        XCTAssertEqual(line.snapshot.materials.count, 1); XCTAssertEqual(line.snapshot.materials.first?.id, note.id)
        XCTAssertEqual(line.snapshot.materials.first?.versions.count, 2)
    }
    @MainActor func testEscAndFocusLossKeepLatestDraft() async throws {
        let (_, store, _, editor) = try await fixture()
        try await editor.openNew(present: false)
        type("Esc 前正文", in: editor); editor.textView.cancelOperation(nil)
        for _ in 0..<30 { await Task.yield() }
        try await editor.flushAutosave()
        let escaped = try await store.pendingNoteDrafts(); XCTAssertEqual(escaped.first?.text, "Esc 前正文")
        try await editor.openNew(present: false); type("失焦前最新正文", in: editor)
        editor.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: editor.window))
        for _ in 0..<30 { await Task.yield() }
        try await editor.flushAutosave()
        let resigned = try await store.pendingNoteDrafts(); XCTAssertEqual(resigned.first?.text, "失焦前最新正文")
        let workspace = try await store.load(); XCTAssertTrue(workspace.materials.isEmpty)
        editor.window?.close()
    }
    @MainActor func testPrivacyHidesNativeContentWithoutDiscardingDraft() async throws {
        let (_, store, line, editor) = try await fixture()
        try await editor.openNew(present: false); type("合成敏感正文", in: editor); try await editor.flushAutosave()
        var snapshot = line.snapshot; snapshot.privacyHidden = true; await line.render(snapshot)
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertEqual(editor.window?.title, L(.contentHidden))
        XCTAssertTrue(editor.textView.enclosingScrollView?.superview?.isHidden == true)
        do { try await editor.hang(); XCTFail("Hidden content must not publish") } catch {}
        let pending = try await store.pendingNoteDrafts(); XCTAssertEqual(pending.first?.text, "合成敏感正文")
        snapshot.privacyHidden = false; await line.render(snapshot)
        XCTAssertEqual(editor.textView.string, "合成敏感正文"); XCTAssertTrue(editor.textView.isEditable)
        editor.window?.close()
    }
    @MainActor func testFailedAutosaveKeepsMemoryAndAllowsRetry() async throws {
        let files = NoteSaveFaultFiles()
        let (_, store, _, editor) = try await fixture(files: files)
        try await editor.openNew(present: false); files.failDraftWrites = true
        type("失败后保留的正文", in: editor)
        do { try await editor.flushAutosave(); XCTFail("Failed disk save must report") } catch {}
        XCTAssertTrue(editor.hasUnsavedInput); XCTAssertEqual(editor.textView.string, "失败后保留的正文")
        files.failDraftWrites = false; try await editor.flushAutosave()
        XCTAssertFalse(editor.hasUnsavedInput)
        let saved = try await store.pendingNoteDrafts(); XCTAssertEqual(saved.first?.text, "失败后保留的正文")
        editor.window?.close()
    }
    @MainActor func testRopePressCreatesNoteAndContextMenuKeepsSettingsAndPaste() throws {
        let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: 1100, height: 64)); target.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        var notes = 0, settings = 0
        target.onNewNote = { notes += 1 }; target.onOpenSettings = { settings += 1 }
        button.performClick(nil)
        XCTAssertEqual(notes, 1); XCTAssertEqual(settings, 0)
        XCTAssertEqual(button.accessibilityLabel(), L(.noteNew)); XCTAssertEqual(button.toolTip, L(.noteHint))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(button.menu(for: event))
        XCTAssertTrue(menu.items.contains { $0.title == L(.intakeSettings) })
        XCTAssertTrue(menu.items.contains { $0.title == L(.pasteInput) })
        XCTAssertTrue(menu.items.contains { $0.title == L(.noteNew) })
    }
}

private final class NoteSaveFaultFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private var handler: (() throws -> Void)?
    var stageWriteHandler: (() throws -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }
    var failDraftWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }
    private let base = SystemFileOperations()
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if failDraftWrites && url.lastPathComponent == "note.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
        if url.pathExtension == "stage" { try stageWriteHandler?() }
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
