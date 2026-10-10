import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class M1IndependentBehaviorAuditTests: XCTestCase {
    @MainActor private func makeTexts(files: any FileOperations = SystemFileOperations()) async throws -> (URL, MaterialStore, Line, [UUID]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-m1-independent-" + UUID().uuidString)
        let store = MaterialStore(root: root, files: files), line = Line(store: store)
        var ids = [UUID]()
        for text in ["A 原始摘录", "B 原始摘录"] {
            let imported = try await store.importMaterial(.text(text, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            await line.render(imported.snapshot)
            ids.append(try XCTUnwrap(imported.snapshot.materials.last?.id))
        }
        return (root, store, line, ids)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor func testConcurrentEditorOpenAdmitsOnlyOneSession() async throws {
        let (_, store, line, ids) = try await makeTexts()
        let editor = TextEditorController(line: line)
        let first = Task { @MainActor () -> Bool in
            do { try await editor.open(ids[0], present: false); return true } catch { return false }
        }
        let second = Task { @MainActor () -> Bool in
            do { try await editor.open(ids[1], present: false); return true } catch { return false }
        }
        let accepted = await [first.value, second.value].filter { $0 }.count
        XCTAssertEqual(accepted, 1, "A single editor must reserve its session before suspending")
        let pending = try await store.pendingEditSessions()
        XCTAssertEqual(pending.count, 1, "A rejected open must not create an orphan editor session")
        if editor.isEditing { try await editor.cancel() }
    }
    @MainActor func testSaveSourceRetainsUnsavedMaterialTitle() async throws {
        let (root, _, line, ids) = try await makeTexts()
        let editor = TextEditorController(line: line)
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root), editor: editor)
        try await detail.open(ids[0], present: false)
        defer { detail.window?.orderOut(nil); detail.window?.close() }
        let fields = try XCTUnwrap(detail.window?.contentView).subviews.flatMap { descendants($0) }.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        XCTAssertEqual(fields.count, 5)
        fields[0].stringValue = "未保存标题草稿"
        fields[1].stringValue = "已登记合成来源"
        try await detail.saveSource()
        XCTAssertEqual(fields[0].stringValue, "未保存标题草稿", "Saving source must not discard a different field's input")
        XCTAssertEqual(line.snapshot.materials.first(where: { $0.id == ids[0] })?.source.manualTitle, "已登记合成来源")
    }
    @MainActor func testMarkedInputSaveIsRejectedWithoutChangingComposition() async throws {
        let (_, store, line, ids) = try await makeTexts()
        let editor = TextEditorController(line: line)
        try await editor.open(ids[0], present: false)
        editor.textView.setMarkedText("输入法候选", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.textView.hasMarkedText())
        let composing = editor.textView.string
        do { try await editor.save(); XCTFail("Marked input must not save") }
        catch { XCTAssertEqual(error as? StoreError, .operationInProgress) }
        XCTAssertEqual(editor.textView.string, composing)
        XCTAssertTrue(editor.textView.hasMarkedText(), "Rejected save must preserve the marked range")
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.first(where: { $0.id == ids[0] })?.versions.count, 1)
        editor.textView.unmarkText()
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        if editor.isEditing { try await editor.cancel() }
    }
    @MainActor func testCopiedSourceDoesNotChangePayloadBytes() async throws {
        let (root, store, line, ids) = try await makeTexts()
        let source = SourceRecord(origin: .clipboard, webURL: URL(string: "https://example.invalid/one"), manualTitle: "合成来源", locator: .printedPage("封二"), isManuallyRegistered: true)
        await line.render(try await store.apply(.setSource(ids[0], source)))
        let url = try await store.payloadURL(of: ids[0])
        let before = try Data(contentsOf: url)
        let board = NSPasteboard(name: .init("InkpegM1Audit-" + UUID().uuidString))
        try await MaterialActions(line: line, root: root, pasteboard: board).copy(ids[0], includeSource: true)
        let copied = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(copied.contains("https://example.invalid/one"))
        XCTAssertTrue(copied.contains("封二"))
        XCTAssertTrue(copied.contains("合成来源"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    @MainActor func testCancelLocksInputBeforeAwaitingDraftWrite() async throws {
        let files = M1AuditFiles()
        let (_, store, line, ids) = try await makeTexts(files: files)
        let editor = TextEditorController(line: line)
        try await editor.open(ids[0], present: false)
        let session = try XCTUnwrap(editor.session)
        editor.text = "取消前草稿"
        let semaphore = DispatchSemaphore(value: 0)
        var wasEditableWhileWriting = false
        files.draftWriteHandler = {
            DispatchQueue.main.async {
                wasEditableWhileWriting = editor.textView.isEditable
                if wasEditableWhileWriting {
                    editor.textView.insertText("新增输入", replacementRange: NSRange(location: editor.textView.string.utf16.count, length: 0))
                    editor.textDidChange(Notification(name: NSText.didChangeNotification))
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 3) == .timedOut { throw StoreError.operationInProgress }
        }
        try await editor.cancel()
        XCTAssertFalse(wasEditableWhileWriting, "Cancel must prevent typing after its captured draft bytes")
        let retained = try String(contentsOf: session.workingURL)
        XCTAssertEqual(retained, editor.text, "The last accepted input must be recoverable")
        let loaded = try await store.load()
        XCTAssertEqual(loaded.materials.first(where: { $0.id == ids[0] })?.versions.count, 1)
    }
    @MainActor func testFailedSaveRetainsEditableDraftAndOriginal() async throws {
        let files = M1AuditFiles()
        let (_, store, line, ids) = try await makeTexts(files: files)
        let editor = TextEditorController(line: line)
        try await editor.open(ids[0], present: false)
        let session = try XCTUnwrap(editor.session)
        let original = try await store.payloadURL(of: ids[0])
        let before = try Data(contentsOf: original)
        editor.text = "保存失败仍保留的中文草稿"
        files.failSnapshotWrite = true
        do { try await editor.save(); XCTFail("Injected state write must fail") } catch {}
        XCTAssertTrue(editor.isEditing)
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertEqual(try String(contentsOf: session.workingURL), editor.text)
        XCTAssertEqual(try Data(contentsOf: original), before)
        files.failSnapshotWrite = false
        try await editor.cancel()
    }
}

private final class M1AuditFiles: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    // Mutable fault controls are protected across the test MainActor and file actor.
    private let controlLock = NSLock()
    private var handler: (() throws -> Void)?
    private var snapshotFailure = false
    var draftWriteHandler: (() throws -> Void)? {
        get { controlLock.lock(); defer { controlLock.unlock() }; return handler }
        set { controlLock.lock(); defer { controlLock.unlock() }; handler = newValue }
    }
    var failSnapshotWrite: Bool {
        get { controlLock.lock(); defer { controlLock.unlock() }; return snapshotFailure }
        set { controlLock.lock(); defer { controlLock.unlock() }; snapshotFailure = newValue }
    }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if url.lastPathComponent.hasPrefix("working."), url.path.contains("/Drafts/") { try draftWriteHandler?() }
        if failSnapshotWrite && url.lastPathComponent == "state.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
