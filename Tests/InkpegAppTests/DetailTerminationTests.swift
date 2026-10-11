import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class DetailTerminationTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-detail-quit-" + UUID().uuidString)
        let files = QuitDetailFiles()
        let line: Line
        let detail: MaterialDetailController
        let clipboard: ClipboardImportService
        var app: AppDelegate!
        var fields: [NSTextField] = []
        var alerts: [NSAlert] = []
        init() {
            _ = NSApplication.shared
            let store = MaterialStore(root: root, files: files)
            line = Line(store: store, hintDefaults: UserDefaults(suiteName: "InkpegQuit-" + UUID().uuidString)!)
            detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: TextEditorController(line: line))
            clipboard = ClipboardImportService(gateway: QuitClipboard(), store: MaterialStore(root: root), capacity: { 1 })
            app = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root), line: line, detail: detail, clipboard: clipboard, terminationResponse: { [weak self] alert in
                self?.alerts.append(alert)
                return .alertThirdButtonReturn // Even a stale clipboard discard response cannot bypass detail.
            })
        }
        func open() async throws {
            let imported = try await line.store.importMaterial(.text("Synthetic original", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
            await line.render(imported.snapshot)
            try await detail.open(XCTUnwrap(imported.snapshot.materials.first?.id), present: false)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            fields = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        }
        func quit() -> NSApplication.TerminateReply { app.applicationShouldTerminate(NSApplication.shared) }
        func assertCancelled(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(quit(), .terminateCancel, file: file, line: line)
            guard let alert = alerts.last else { XCTFail("Missing actionable notice", file: file, line: line); return }
            XCTAssertEqual(alert.buttons.count, 1, "Only cancel is safe until detail is handled", file: file, line: line)
            let notice = alert.messageText + alert.informativeText
            for field in fields where !field.stringValue.isEmpty {
                XCTAssertFalse(notice.contains(field.stringValue), "Quit notice must not reveal draft content", file: file, line: line)
            }
        }
        func close() async throws {
            clipboard.stop(); detail.chooseUnsavedChanges = { .discard }
            if line.snapshot.privacyHidden { var visible = line.snapshot; visible.privacyHidden = false; await line.render(visible) }
            try await detail.dismiss()
        }
    }
    @MainActor func testTitleOnlyDraftCancelsActualApplicationTermination() async throws {
        let f = Fixture(); try await f.open(); f.fields[0].stringValue = "PRIVATE_TITLE"
        f.assertCancelled(); XCTAssertEqual(f.fields[0].stringValue, "PRIVATE_TITLE")
        try await f.close(); XCTAssertEqual(f.quit(), .terminateNow)
    }
    @MainActor func testSourceOnlyDraftCancelsActualApplicationTermination() async throws {
        let f = Fixture(); try await f.open(); f.fields[1].stringValue = "PRIVATE_SOURCE"
        f.assertCancelled(); XCTAssertEqual(f.fields[1].stringValue, "PRIVATE_SOURCE")
        try await f.close()
    }
    @MainActor func testBothDraftsCancelThenSuccessfulSaveAllowsQuit() async throws {
        let f = Fixture(); try await f.open(); f.fields[0].stringValue = "PRIVATE_TITLE"; f.fields[1].stringValue = "PRIVATE_SOURCE"
        f.assertCancelled(); try await f.detail.save(); XCTAssertEqual(f.quit(), .terminateNow)
        let saved = try await f.line.store.load()
        XCTAssertEqual(saved.materials.first?.title, "PRIVATE_TITLE"); XCTAssertEqual(saved.materials.first?.source.manualTitle, "PRIVATE_SOURCE")
        try await f.close()
    }
    @MainActor func testActiveFieldEditorIsCommittedBeforeQuitDecision() async throws {
        let f = Fixture(); try await f.open()
        let window = try XCTUnwrap(f.detail.window)
        XCTAssertTrue(window.makeFirstResponder(f.fields[0]))
        let editor = try XCTUnwrap(f.fields[0].currentEditor())
        editor.string = "ACTIVE_UNCOMMITTED_TITLE"
        XCTAssertTrue(window.firstResponder === editor, "Fixture must reach the active field editor")
        f.assertCancelled()
        XCTAssertEqual(f.fields[0].stringValue, "ACTIVE_UNCOMMITTED_TITLE")
        XCTAssertNil(f.fields[0].currentEditor(), "Quit must finish the field editor using detail save semantics")
        try await f.close()
    }
    @MainActor func testActualHeldSaveBlocksQuitEvenWhenControlsMatchSavedValues() async throws {
        let f = Fixture(); try await f.open(); let original = f.fields[0].stringValue
        f.fields[0].stringValue = "COMMIT_IN_FLIGHT"
        f.files.arm(holdAt: 1)
        let saving = Task { try await f.detail.save() }
        for _ in 0..<2000 where !f.files.isHeld { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(f.files.isHeld, "Actual state write must be held")
        // A save owns its captured draft; do not let a dirty-only guard stand in for in-flight protection.
        f.fields[0].stringValue = original
        XCTAssertFalse(f.detail.hasUnsavedChanges)
        f.assertCancelled()
        f.files.release(); try await saving.value
        f.fields[0].stringValue = "COMMIT_IN_FLIGHT"
        XCTAssertEqual(f.quit(), .terminateNow)
        let saved = try await f.line.store.load(); XCTAssertEqual(saved.materials.first?.title, "COMMIT_IN_FLIGHT")
        try await f.close()
    }
    @MainActor func testFirstWriteFailureRetainsDraftAndBlocksQuit() async throws { try await failedWrite(1) }
    @MainActor func testSecondWriteFailureRetainsSourceAndBlocksQuit() async throws { try await failedWrite(2) }
    @MainActor private func failedWrite(_ index: Int) async throws {
        let f = Fixture(); try await f.open(); f.fields[0].stringValue = "PRIVATE_TITLE"; f.fields[1].stringValue = "PRIVATE_SOURCE"
        f.files.arm(failAt: index)
        do { try await f.detail.save(); XCTFail("Expected actual write failure") } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertEqual(f.files.writes, index); f.assertCancelled()
        XCTAssertEqual(f.fields[0].stringValue, "PRIVATE_TITLE"); XCTAssertEqual(f.fields[1].stringValue, "PRIVATE_SOURCE")
        let saved = try await f.line.store.load()
        XCTAssertEqual(saved.materials.first?.title, index == 1 ? "Synthetic original" : "PRIVATE_TITLE")
        XCTAssertNil(saved.materials.first?.source.manualTitle)
        f.files.arm(); try await f.detail.save(); XCTAssertEqual(f.quit(), .terminateNow)
        XCTAssertEqual(f.files.writes, index == 1 ? 2 : 1)
        try await f.close()
    }
    @MainActor func testHiddenDraftStillBlocksQuitWithoutRevealingContent() async throws {
        let f = Fixture(); try await f.open(); f.fields[0].stringValue = "PRIVATE_TITLE"; f.fields[1].stringValue = "PRIVATE_SOURCE"
        var hidden = f.line.snapshot; hidden.privacyHidden = true; await f.line.render(hidden)
        f.assertCancelled(); XCTAssertTrue(f.detail.window?.contentView?.subviews.first?.isHidden == true)
        XCTAssertEqual(f.fields[0].stringValue, "PRIVATE_TITLE"); XCTAssertEqual(f.fields[1].stringValue, "PRIVATE_SOURCE")
        try await f.close()
    }
    @MainActor func testClipboardDiscardCannotOverrideDetailButWorksAfterExplicitHandling() async throws {
        let f = Fixture(); try await f.open()
        var pinned = try await f.line.store.load(); pinned.materials[0].pinned = true
        try JSONEncoder().encode(pinned).write(to: f.root.appendingPathComponent("state.json"), options: .atomic)
        try await f.line.store.setClipboardEnabled(true); await f.clipboard.start()
        XCTAssertEqual(f.clipboard.pendingCount, 1)
        f.fields[0].stringValue = "PRIVATE_TITLE"; f.assertCancelled()
        XCTAssertEqual(f.clipboard.pendingCount, 1, "Detail guard precedes destructive clipboard choice")
        f.detail.chooseUnsavedChanges = { .discard }; try await f.detail.dismiss()
        XCTAssertEqual(f.quit(), .terminateNow); XCTAssertEqual(f.clipboard.pendingCount, 0)
        try await f.close()
    }
    @MainActor func testCleanDetailAllowsQuitWithoutNotice() async throws {
        let f = Fixture(); try await f.open(); XCTAssertEqual(f.quit(), .terminateNow); XCTAssertTrue(f.alerts.isEmpty)
        try await f.close()
    }
}

@MainActor private final class QuitClipboard: ClipboardGateway {
    var changeCount = 1
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 1, requests: [.text("Synthetic pending clipboard", SourceRecord(origin: .clipboard))]) }
}

private final class QuitDetailFiles: FileOperations, @unchecked Sendable {
    private let base = SystemFileOperations(), lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var failure: Int?, hold: Int?, count = 0, held = false
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    func arm(failAt: Int? = nil, holdAt: Int? = nil) { lock.lock(); defer { lock.unlock() }; failure = failAt; hold = holdAt; count = 0; held = false }
    func release() { gate.signal() }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "state.json" {
            lock.lock(); count += 1; let fail = count == failure, wait = count == hold; if wait { held = true }; lock.unlock()
            if wait, gate.wait(timeout: .now() + 10) == .timedOut { throw StoreError.operationInProgress }
            if fail { throw StoreError.unavailableSpace }
        }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
