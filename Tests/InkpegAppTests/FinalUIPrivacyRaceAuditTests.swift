import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class FinalUIPrivacyRaceAuditTests: XCTestCase {
    @MainActor private func fixture() async throws -> (URL, MaterialStore, Line, UUID, FinalUIPrivacyAuditFiles) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-final-ui-privacy-synthetic-" + UUID().uuidString)
        let files = FinalUIPrivacyAuditFiles(), store = MaterialStore(root: root, files: files), line = Line(store: store)
        let imported = try await store.importMaterial(.text("仅合成敏感正文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        return (root, store, line, try XCTUnwrap(imported.snapshot.materials.first?.id), files)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func hideWhileStoreIsSuspended(_ files: FinalUIPrivacyAuditFiles, line: Line, trigger: String) {
        files.trigger = trigger
        files.handler = {
            let signal = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                Task { @MainActor in
                    var hidden = line.snapshot; hidden.privacyHidden = true
                    Task { @MainActor in await line.render(hidden) }
                    for _ in 0..<1000 {
                        if line.snapshot.privacyHidden { files.hideObserved = true; signal.signal(); return }
                        await Task.yield()
                    }
                    signal.signal()
                }
            }
            if signal.wait(timeout: .now() + 3) == .timedOut { throw StoreError.operationInProgress }
        }
    }
    @MainActor func testTextSaveCannotUndoHideReceivedDuringDraftWrite() async throws {
        let (_, store, line, id, files) = try await fixture()
        let editor = TextEditorController(line: line)
        try await editor.open(id, present: false)
        editor.text = "保存中的合成正文"
        hideWhileStoreIsSuspended(files, line: line, trigger: "working")
        defer { files.handler = nil; editor.window?.orderOut(nil) }
        try await editor.save()
        XCTAssertGreaterThan(files.hits, 0, "The injected boundary must actually be reached")
        XCTAssertTrue(files.hideObserved, "The later hide request must actually precede save completion")
        XCTAssertTrue(line.snapshot.privacyHidden, "A completed text save must not undo a newer hide request")
        let saved = try await store.load(); XCTAssertEqual(saved.materials.first?.versions.count, 2)
    }
    @MainActor func testUnifiedDetailSaveCannotUndoHideReceivedDuringSourceStateWrite() async throws {
        let (root, _, line, id, files) = try await fixture()
        let board = NSPasteboard(name: .init("InkpegFinalUIPrivacy-" + UUID().uuidString))
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: board), editor: TextEditorController(line: line))
        try await detail.open(id, present: false)
        let fields = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        fields[1].stringValue = "合成来源"
        hideWhileStoreIsSuspended(files, line: line, trigger: "state")
        defer { files.handler = nil; detail.window?.close() }
        try await detail.save()
        XCTAssertGreaterThan(files.hits, 0)
        XCTAssertTrue(files.hideObserved, "The later hide request must actually precede save completion")
        XCTAssertTrue(line.snapshot.privacyHidden, "A completed source save must not undo a newer hide request")
        XCTAssertTrue(detail.window?.contentView?.subviews.first?.isHidden == true, "The detail form must remain concealed")
        XCTAssertEqual(detail.window?.title, L(.contentHidden))
        XCTAssertTrue(fields.allSatisfy { !$0.isEditable && !$0.isSelectable })
        XCTAssertEqual(fields[1].stringValue, "合成来源")
        XCTAssertFalse(detail.hasUnsavedChanges)
    }
}

private final class FinalUIPrivacyAuditFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock(), base = SystemFileOperations()
    private var callback: (() throws -> Void)?
    private var kind = "", hitCount = 0, observedHide = false
    var hideObserved: Bool { get { lock.lock(); defer { lock.unlock() }; return observedHide } set { lock.lock(); defer { lock.unlock() }; observedHide = newValue } }
    var handler: (() throws -> Void)? { get { lock.lock(); defer { lock.unlock() }; return callback } set { lock.lock(); defer { lock.unlock() }; callback = newValue } }
    var trigger: String { get { lock.lock(); defer { lock.unlock() }; return kind } set { lock.lock(); defer { lock.unlock() }; kind = newValue } }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return hitCount }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        let current = trigger
        if (current == "working" && url.lastPathComponent.hasPrefix("working.")) || (current == "state" && url.lastPathComponent == "state.json") {
            lock.lock(); hitCount += 1; lock.unlock()
            try handler?()
        }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
