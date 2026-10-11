import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class RecentMaterialsTests: XCTestCase {
    @MainActor private func suspendedFixture() async throws -> (MaterialStore, Line, WorkflowRecoveryController, RecentPrivacyFiles, UUID) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-recent-race-" + UUID().uuidString)
        let seedStore = MaterialStore(root: root)
        let first = try await seedStore.importMaterial(.text("异步隐私合成资料", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(first.snapshot.materials.first?.id)
        let seed = try await seedStore.apply(.takeDown(id))
        let files = RecentPrivacyFiles(), store = MaterialStore(root: root, files: files), line = Line(store: store)
        await line.render(seed)
        return (store, line, WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root)), files, id)
    }
    @MainActor private func hideAtStoreBoundary(_ files: RecentPrivacyFiles, line: Line, write: Bool) {
        files.onWrite = write
        files.handler = {
            let signal = DispatchSemaphore(value: 0)
            Task { @MainActor in
                var snapshot = line.snapshot; snapshot.privacyHidden = true
                await line.render(snapshot)
                files.hideObserved = line.snapshot.privacyHidden
                signal.signal()
            }
            if signal.wait(timeout: .now() + 3) == .timedOut { throw StoreError.operationInProgress }
        }
    }
    @MainActor func testListLoadCannotReopenAfterInFlightPrivacyHide() async throws {
        let (_, line, controller, files, _) = try await suspendedFixture()
        hideAtStoreBoundary(files, line: line, write: false)
        defer { files.handler = nil; controller.recentWindow?.close() }
        await controller.showTakenDown()
        XCTAssertGreaterThan(files.hits, 0, "The store read must actually hit the suspension boundary")
        XCTAssertTrue(files.hideObserved, "Privacy must hide before load returns")
        XCTAssertTrue(line.snapshot.privacyHidden)
        XCTAssertFalse(controller.recentWindow?.isVisible == true)
        XCTAssertTrue(controller.takenDownRecords.isEmpty)
        XCTAssertTrue(line.inputFeedback.isEmpty)
    }
    @MainActor func testRehangAbortsWhenHiddenDuringLoad() async throws {
        let (store, line, controller, files, id) = try await suspendedFixture()
        hideAtStoreBoundary(files, line: line, write: false)
        defer { files.handler = nil }
        try await controller.rehang(id)
        XCTAssertGreaterThan(files.hits, 0)
        XCTAssertTrue(files.hideObserved)
        XCTAssertTrue(line.snapshot.privacyHidden)
        XCTAssertTrue(line.inputFeedback.isEmpty)
        let disk = try await store.load()
        XCTAssertEqual(disk.materials.first?.status, .takenDown, "Hide before hang begins must cancel the UI action")
    }
    @MainActor func testCompletedRehangPreservesHideDuringStateWrite() async throws {
        let (store, line, controller, files, id) = try await suspendedFixture()
        _ = try await store.load()
        hideAtStoreBoundary(files, line: line, write: true)
        defer { files.handler = nil }
        try await controller.rehang(id)
        XCTAssertGreaterThan(files.hits, 0)
        XCTAssertTrue(files.hideObserved)
        XCTAssertTrue(line.snapshot.privacyHidden)
        XCTAssertFalse(controller.recentWindow?.isVisible == true)
        XCTAssertTrue(line.inputFeedback.isEmpty, "Completion while hidden must not publish a success message")
        let disk = try await store.load()
        XCTAssertEqual(disk.materials.first?.status, .hanging, "The completed command should remain committed while presentation stays hidden")
    }

    @MainActor func testLongTakenDownListOpensAtTopAndPreservesReadingPositionOnRefresh() async throws {
        let (store, line, controller) = fixture()
        for index in 0..<20 {
            _ = try await store.importMaterial(.text("合成列表第\(index)项", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 25)
        }
        await line.render(try await store.apply(.takeDownUnpinned(MatterGroup.ungroupedID)))
        await controller.showTakenDown()
        let window = try XCTUnwrap(controller.recentWindow); defer { window.close() }
        let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
        window.contentView?.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let first = try XCTUnwrap(descendants(document).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("合成列表第0项") })
        let firstFrame = document.convert(first.bounds, from: first)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(firstFrame), "The first ordered row must be on the first screen")
        let initialDistance = document.bounds.maxY - scroll.documentVisibleRect.maxY
        XCTAssertEqual(initialDistance, 0, accuracy: 1, "The initial viewport must start at the top")
        let point = NSPoint(x: 0, y: (document.bounds.height - scroll.contentView.bounds.height) / 2)
        scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
        let distance = document.bounds.maxY - scroll.documentVisibleRect.maxY
        XCTAssertGreaterThan(distance, 50, "Move away from the top before testing refresh")
        let id = try XCTUnwrap(line.snapshot.materials.first?.id)
        await line.render(try await store.apply(.renameMaterial(id, "更新后的合成标题")))
        let refreshed = try XCTUnwrap(window.contentView as? NSScrollView)
        window.contentView?.layoutSubtreeIfNeeded()
        let nextDocument = try XCTUnwrap(refreshed.documentView)
        XCTAssertEqual(nextDocument.bounds.maxY - refreshed.documentVisibleRect.maxY, distance, accuracy: 1, "A snapshot refresh must preserve the reading offset from the top")
    }

    @MainActor private func fixture() -> (MaterialStore, Line, WorkflowRecoveryController) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-recent-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        return (store, line, WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root)))
    }

    @MainActor func testTakenDownListUsesStableOrderAndHidesWhenPrivacyChanges() async throws {
        let (store, line, controller) = fixture()
        var ids = [UUID]()
        for title in ["第一份合成资料", "第二份合成资料", "仍在绳上的合成资料"] {
            let result = try await store.importMaterial(.text(title, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 5)
            if case .hanging(let id) = result.disposition { ids.append(id) }
        }
        _ = try await store.apply(.takeDown(ids[1]))
        await line.render(try await store.apply(.takeDown(ids[0])))
        XCTAssertEqual(controller.takenDownRecords.map(\.id), [ids[0], ids[1]])
        await controller.showTakenDown()
        let window = try XCTUnwrap(controller.recentWindow)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let labels = descendants(try XCTUnwrap(window.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("第一份合成资料") })
        XCTAssertTrue(labels.contains { $0.contains(L(.inputText)) })
        XCTAssertFalse(labels.contains { $0.contains("仍在绳上的合成资料") })
        var hidden = line.snapshot; hidden.privacyHidden = true
        await line.render(hidden)
        XCTAssertFalse(window.isVisible, "An open taken-down list must close as soon as privacy hides content")
        await controller.showTakenDown()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.takenDownRecords.isEmpty)
    }

    @MainActor func testListHangButtonRestoresCurrentEditedVersion() async throws {
        let (store, line, controller) = fixture()
        let first = try await store.importMaterial(.text("合成原文", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(first.snapshot.materials.first)
        let edit = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try Data("合成修订文".utf8).write(to: edit.workingURL)
        let edited = try await store.finishEditing(edit, result: .save(edit.workingURL))
        let version = try XCTUnwrap(edited.materials.first?.activeVersionID)
        await line.render(try await store.apply(.takeDown(record.id)))
        await controller.showTakenDown()
        let window = try XCTUnwrap(controller.recentWindow); defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSButton }.first { $0.title == L(.rehangMaterial) })
        button.performClick(nil)
        for _ in 0..<20 where line.snapshot.materials.first?.status != .hanging { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(line.snapshot.materials.first?.status, .hanging)
        XCTAssertEqual(line.snapshot.materials.first?.activeVersionID, version)
        XCTAssertTrue(controller.takenDownRecords.isEmpty)
        let payload = try await store.payloadURL(of: record.id)
        XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "合成修订文")
    }

    @MainActor func testUndoRestoresTakenDownBatchAndExpires() async throws {
        let (store, line, controller) = fixture()
        for text in ["合成一", "合成二"] {
            _ = try await store.importMaterial(.text(text, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        }
        let snapshot = try await store.load(), ids = snapshot.materials.map(\.id)
        await line.render(try await store.apply(.takeDownUnpinned(MatterGroup.ungroupedID)))
        let now = Date()
        controller.noteTakenDown(ids, at: now)
        XCTAssertTrue(controller.canUndoTakeDown(at: now.addingTimeInterval(7)))
        try await controller.undoTakeDown(at: now.addingTimeInterval(1))
        XCTAssertEqual(line.snapshot.materials.filter { $0.status == .hanging }.count, 2)
        XCTAssertFalse(controller.canUndoTakeDown(at: now))
        await line.render(try await store.apply(.takeDown(ids[0])))
        controller.noteTakenDown([ids[0]], at: now)
        XCTAssertFalse(controller.canUndoTakeDown(at: now.addingTimeInterval(9)))
        try await controller.undoTakeDown(at: now.addingTimeInterval(9))
        XCTAssertEqual(line.snapshot.materials.first { $0.id == ids[0] }?.status, .takenDown)
    }

    @MainActor func testHiddenOrFullShelfCannotUndoAndRetainedRecordRemains() async throws {
        let (store, line, controller) = fixture()
        let result = try await store.importMaterial(.text("合成取下卡片", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 2)
        let id = try XCTUnwrap(result.snapshot.materials.first?.id)
        await line.render(try await store.apply(.takeDown(id)))
        controller.noteTakenDown([id])
        var hidden = line.snapshot; hidden.privacyHidden = true
        await line.render(hidden)
        XCTAssertFalse(controller.canUndoTakeDown())
        try await controller.undoTakeDown()
        XCTAssertEqual(line.snapshot.materials.first?.status, .takenDown)
        var visible = line.snapshot; visible.privacyHidden = false
        await line.render(visible)
        line.maxItems = 0
        controller.noteTakenDown([id])
        do { try await controller.undoTakeDown(); XCTFail("Full shelf must reject a hang") }
        catch { XCTAssertEqual(error as? StoreError, .budgetExceeded) }
        let disk = try await store.load()
        XCTAssertEqual(disk.materials.first?.status, .takenDown)
        XCTAssertTrue(controller.canUndoTakeDown(), "A failed undo must remain available for retry within its deadline")
    }

    @MainActor func testExplicitPasteOfTakenDownMaterialReportsSaved() async throws {
        let (store, line, _) = fixture()
        let request = ImportRequest.text("合成手动挂回", SourceRecord(origin: .clipboard))
        let first = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(first.snapshot.materials.first?.id)
        await line.render(try await store.apply(.takeDown(id)))
        let service = ClipboardImportService(gateway: RecentClipboard(request), store: store)
        let intake = LineIntakeController(line: line, service: service)
        service.onSnapshot = { await line.render($0) }
        service.onImported = { _, _ in intake.imported() }
        service.onStateChanged = { intake.refresh() }
        await service.start(); await intake.paste()
        XCTAssertEqual(line.inputFeedback, L(.inputSaved))
        XCTAssertEqual(line.snapshot.materials.first?.id, id)
        XCTAssertEqual(line.snapshot.materials.first?.status, .hanging)
    }
}

@MainActor private final class RecentClipboard: ClipboardGateway {
    var changeCount = 1
    let request: ImportRequest
    init(_ request: ImportRequest) { self.request = request }
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: changeCount, requests: [request]) }
}

private final class RecentPrivacyFiles: FileOperations, @unchecked Sendable {
    private let base = SystemFileOperations(), lock = NSLock()
    private var callback: (() throws -> Void)?
    private var writes = false, observed = false, hitCount = 0
    var handler: (() throws -> Void)? { get { lock.lock(); defer { lock.unlock() }; return callback } set { lock.lock(); defer { lock.unlock() }; callback = newValue } }
    var onWrite: Bool { get { lock.lock(); defer { lock.unlock() }; return writes } set { lock.lock(); defer { lock.unlock() }; writes = newValue } }
    var hideObserved: Bool { get { lock.lock(); defer { lock.unlock() }; return observed } set { lock.lock(); defer { lock.unlock() }; observed = newValue } }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return hitCount }
    private func boundary(_ url: URL, write: Bool) throws {
        guard url.lastPathComponent == "state.json", onWrite == write, let handler else { return }
        lock.lock(); hitCount += 1; lock.unlock()
        try handler()
    }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try boundary(url, write: false); return try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws { try boundary(url, write: true); try base.writeAtomic(data, to: url) }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
