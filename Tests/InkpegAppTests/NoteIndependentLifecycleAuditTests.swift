import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class NoteIndependentLifecycleAuditTests: XCTestCase {
    @MainActor private func fixture(files: any FileOperations = SystemFileOperations()) async throws -> (MaterialStore, Line, NoteEditorController) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-independent-ui-" + UUID().uuidString)
        let store = MaterialStore(root: root, files: files), line = Line(store: store)
        try await line.load()
        let editor = NoteEditorController(line: line)
        try await editor.openNew(present: false)
        return (store, line, editor)
    }
    @MainActor private func type(_ body: String, editor: NoteEditorController) {
        editor.textView.string = body
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    @MainActor func testFailedAutosaveRevertedToDurableTextCanDismiss() async throws {
        let files = NoteLifecycleFaultFiles()
        let (_, _, editor) = try await fixture(files: files)
        defer { editor.window?.close() }
        type("durable body", editor: editor)
        try await editor.flushAutosave()
        files.failDraft = true
        type("unsaved body", editor: editor)
        do { try await editor.flushAutosave(); XCTFail("Injected draft write must fail") } catch {}
        files.failDraft = false
        type("durable body", editor: editor)
        XCTAssertFalse(editor.hasUnsavedInput)
        do { try await editor.dismiss() }
        catch {
            XCTAssertEqual(error as? StoreError, .unavailableSpace)
            XCTFail("Reverting failed input to the already durable body must clear the stale save error and allow dismissal")
        }
        XCTAssertFalse(editor.isBusy)
    }

    @MainActor func testHideDuringPublicationKeepsLatestPrivacyChoice() async throws {
        let files = NoteLifecycleFaultFiles()
        let (store, line, editor) = try await fixture(files: files)
        defer { files.stageWriteHandler = nil; editor.window?.close() }
        type("private synthetic body", editor: editor)
        try await editor.flushAutosave()
        let signal = DispatchSemaphore(value: 0)
        files.stageWriteHandler = {
            DispatchQueue.main.async {
                Task { @MainActor in
                    var hidden = line.snapshot; hidden.privacyHidden = true
                    await line.render(hidden)
                    XCTAssertEqual(editor.window?.title, L(.contentHidden))
                    XCTAssertTrue(editor.textView.enclosingScrollView?.superview?.isHidden == true)
                    XCTAssertFalse(editor.textView.isEditable)
                    signal.signal()
                }
            }
            if signal.wait(timeout: .now() + 3) == .timedOut { throw StoreError.operationInProgress }
        }
        try await editor.hang()
        XCTAssertTrue(line.snapshot.privacyHidden, "Publication must preserve the hide request received while writing")
        let saved = try await store.load(), note = try XCTUnwrap(saved.materials.first)
        let payload = try await store.payloadURL(of: note.id)
        XCTAssertEqual(try String(contentsOf: payload), "private synthetic body")
    }

    @MainActor func testRapidEditsAndConcurrentHangPublishOnlyLatestCompleteText() async throws {
        let (store, line, editor) = try await fixture()
        let id = try XCTUnwrap(editor.draft?.materialID)
        for index in 0..<40 {
            type("中文最新完整正文 \(index)\n第二行 \(index)", editor: editor)
            await Task.yield()
        }
        let expected = editor.textView.string
        let first = Task { @MainActor in do { try await editor.hang(); return true } catch { return false } }
        let second = Task { @MainActor in do { try await editor.hang(); return true } catch { return false } }
        let successes = await [first.value, second.value]
        XCTAssertEqual(successes.filter { $0 }.count, 1)
        XCTAssertEqual(line.snapshot.materials.count, 1)
        XCTAssertEqual(line.snapshot.materials.first?.id, id)
        XCTAssertEqual(line.snapshot.materials.first?.versions.count, 1)
        let payload = try await store.payloadURL(of: id)
        XCTAssertEqual(try String(contentsOf: payload), expected)
    }

    @MainActor func testAutosaveKeepsTheSameTextViewAndMarkedRange() async throws {
        let (store, _, editor) = try await fixture()
        defer { editor.window?.close() }
        let view = editor.textView
        view.setMarkedText("中文合成候选", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 0, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        let string = view.string, marked = view.markedRange(), selected = view.selectedRange()
        try await editor.flushAutosave()
        XCTAssertTrue(editor.textView === view)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), marked)
        XCTAssertEqual(view.selectedRange(), selected)
        let pending = try await store.pendingNoteDrafts()
        XCTAssertEqual(pending.first?.text, string)
    }

    @MainActor func testRepeatedCommandReturnDoesNotReportOperationFailure() async throws {
        let (_, line, editor) = try await fixture()
        type("repeat shortcut body", editor: editor)
        try await editor.flushAutosave()
        var failures = 0, completions = 0
        editor.onError = { _ in failures += 1 }
        editor.onHung = { completions += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.textView.keyDown(with: event)
        editor.textView.keyDown(with: event)
        for _ in 0..<1000 {
            if completions > 0 && !editor.isBusy { break }
            await Task.yield()
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(line.snapshot.materials.count, 1)
        XCTAssertEqual(failures, 0, "A redundant hang shortcut is an expected reservation conflict, not an operation failure dialog")
    }
}

private final class NoteLifecycleFaultFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    private var handler: (() throws -> Void)?
    var stageWriteHandler: (() throws -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }
    var failDraft: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); defer { lock.unlock() }; fail = newValue }
    }
    private let base = SystemFileOperations()
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if failDraft && url.lastPathComponent == "note.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
        if url.pathExtension == "stage" { try stageWriteHandler?() }
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
