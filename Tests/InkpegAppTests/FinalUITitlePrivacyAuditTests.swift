import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class FinalUITitlePrivacyAuditTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor func testActualUnifiedSaveKeepsLaterHideAndIncompleteSourceInput() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-final-title-synthetic-" + UUID().uuidString)
        let files = FinalUITitleAuditFiles(), store = MaterialStore(root: root, files: files), line = Line(store: store)
        let imported = try await store.importMaterial(.text("合成标题保存原文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let board = NSPasteboard(name: .init("InkpegFinalTitle-" + UUID().uuidString))
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: board), editor: TextEditorController(line: line))
        try await detail.open(id, present: false)
        let views = descendants(try XCTUnwrap(detail.window?.contentView))
        let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let title = "通过真实按钮保存的合成标题"
        fields[0].stringValue = title; fields[1].stringValue = "必须保留的未保存来源"
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L(.saveDetails) })
        var errors = [Error](); detail.onError = { errors.append($0) }
        files.stateWriteHandler = {
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
        defer { files.stateWriteHandler = nil; detail.window?.close() }
        button.performClick(nil)
        var saved = false
        for _ in 0..<500 {
            let current = try await store.load()
            if current.materials.first?.title == title && line.snapshot.materials.first?.title == title { saved = true; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(saved, "The native button must actually commit the requested title")
        for _ in 0..<100 where errors.isEmpty { await Task.yield() }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? StoreError, .invalidSource)
        XCTAssertTrue(detail.hasUnsavedChanges)
        XCTAssertGreaterThan(files.hits, 0); XCTAssertTrue(files.hideObserved)
        XCTAssertTrue(line.snapshot.privacyHidden, "A later hide must survive the asynchronous title-save callback")
        XCTAssertTrue(detail.window?.contentView?.subviews.first?.isHidden == true)
        XCTAssertEqual(detail.window?.title, L(.contentHidden))
        XCTAssertEqual(fields[1].stringValue, "必须保留的未保存来源")
        let savedSnapshot = try await store.load()
        XCTAssertNil(savedSnapshot.materials.first?.source.manualTitle)
    }
}

private final class FinalUITitleAuditFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock(), base = SystemFileOperations()
    private var callback: (() throws -> Void)?, count = 0, observedHide = false
    var stateWriteHandler: (() throws -> Void)? { get { lock.lock(); defer { lock.unlock() }; return callback } set { lock.lock(); defer { lock.unlock() }; callback = newValue } }
    var hideObserved: Bool { get { lock.lock(); defer { lock.unlock() }; return observedHide } set { lock.lock(); defer { lock.unlock() }; observedHide = newValue } }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "state.json", let handler = stateWriteHandler {
            lock.lock(); count += 1; lock.unlock()
            try handler()
        }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
