import XCTest
@testable import InkpegCore

final class ClipboardImportTests: XCTestCase {
    @MainActor
    func testExplicitDiscardUnblocksWithoutDeletingSources() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let first = try await store.importMaterial(.text("固定", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = first.snapshot; seed.materials[0].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        let pinned = fixture.makeStore(), board = TestClipboard(.file(fixture.source, .clipboard))
        let service = ClipboardImportService(gateway: board, store: pinned, capacity: { 1 })
        try await store.setClipboardEnabled(true)
        await service.start()
        XCTAssertTrue(service.canDiscardPending)
        XCTAssertTrue(service.discardPending())
        XCTAssertEqual(service.pendingCount, 0)
        await service.poll()
        XCTAssertEqual(service.pendingCount, 0, "Explicit discard must not immediately re-enqueue the same clipboard")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        _ = try await pinned.apply(.takeDown(try XCTUnwrap(seed.materials.first?.id)))
        board.changeCount += 1; board.requests = [.text("后续正常内容", SourceRecord(origin: .clipboard))]
        await service.poll()
        let saved = try await pinned.load()
        XCTAssertEqual(saved.materials.count, 2)
    }
    @MainActor
    func testBusyImportCannotHaveItsQueueDiscarded() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore(), board = TestClipboard(.text("合成", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        service.onSnapshot = { _ in XCTAssertFalse(service.discardPending(), "In-flight import must remain protected") }
        try await store.setClipboardEnabled(true)
        await service.start()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
    }
    @MainActor
    func testMultipleFileCopiesPreserveEachOriginal() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let second = fixture.source.deletingLastPathComponent().appendingPathComponent("second.txt")
        try Data("第二份合成文件".utf8).write(to: second)
        let board = TestClipboard(.file(fixture.source, .clipboard))
        board.requests.append(.file(second, .clipboard))
        let service = ClipboardImportService(gateway: board, store: store)
        try await store.setClipboardEnabled(true)
        await service.start()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "第二份合成文件")
    }
    @MainActor
    func testDeletedPendingFileCanBeExplicitlyDiscarded() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let first = try await store.importMaterial(.text("固定", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = first.snapshot; seed.materials[0].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        let pinned = fixture.makeStore(), board = TestClipboard(.file(fixture.source, .clipboard))
        let service = ClipboardImportService(gateway: board, store: pinned, capacity: { 1 })
        try await store.setClipboardEnabled(true)
        await service.start()
        // Preserve the synthetic original outside its former path rather than delete it.
        try FileManager.default.moveItem(at: fixture.source, to: fixture.source.appendingPathExtension("preserved"))
        await service.retryPending()
        XCTAssertEqual(service.state, .changedFile)
        XCTAssertTrue(service.discardPending())
        XCTAssertEqual(service.pendingCount, 0)
    }
    @MainActor
    func testRejectedStateStaysVisibleUntilAChangedClipboardArrives() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = TestClipboard(.text(String(repeating: "a", count: ClipboardLimits.textBytes + 1), SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        try await store.setClipboardEnabled(true)
        await service.start(); await service.poll()
        XCTAssertEqual(service.state, .rejected)
        XCTAssertEqual(board.reads, 1)
        board.changeCount += 1; board.requests = [.text("有效合成文字", SourceRecord(origin: .clipboard))]
        await service.poll()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
        XCTAssertEqual(service.state, .active)
    }
    @MainActor
    func testOversizeFileIsRejectedBeforeQueueAndNextTextCanArrive() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        try Data(repeating: 65, count: 1025).write(to: fixture.source)
        let board = TestClipboard(.file(fixture.source, .clipboard))
        let service = ClipboardImportService(gateway: board, store: store)
        try await store.setClipboardEnabled(true)
        await service.start()
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(service.state, .rejected)
        board.changeCount += 1; board.requests = [.text("正常文本", SourceRecord(origin: .clipboard))]
        await service.poll()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
    }
    @MainActor
    func testChangedPendingFileCannotSilentlyImportLaterBytes() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let first = try await store.importMaterial(.text("固定卡片", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = first.snapshot; seed.materials[0].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        let pinnedStore = fixture.makeStore()
        let board = TestClipboard(.file(fixture.source, .clipboard))
        let service = ClipboardImportService(gateway: board, store: pinnedStore, capacity: { 1 })
        try await store.setClipboardEnabled(true)
        await service.start()
        XCTAssertEqual(service.pendingCount, 1)
        try Data("后来内容，不能冒充原输入".utf8).write(to: fixture.source)
        _ = try await pinnedStore.apply(.takeDown(try XCTUnwrap(seed.materials.first?.id)))
        await service.retryPending()
        let saved = try await pinnedStore.load()
        XCTAssertEqual(saved.materials.count, 1, "Changed source must remain unresolved instead of silently importing replacement bytes")
        XCTAssertEqual(service.pendingCount, 1)
    }
    @MainActor
    func testHiddenDuringSnapshotCallbackDoesNotRevealImportedContent() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = TestClipboard(.text("合成隐私内容", SourceRecord(origin: .clipboard)))
        var hidden = false, revealed = false
        let service = ClipboardImportService(gateway: board, store: store, canRead: { !hidden })
        service.onSnapshot = { _ in hidden = true }
        service.onImported = { _, _ in revealed = true }
        try await store.setClipboardEnabled(true)
        await service.start()
        XCTAssertFalse(revealed)
    }
    @MainActor
    func testSameScreenshotFromFolderAndClipboardKeepsOneCardAndOriginalSource() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC")!
        try png.write(to: fixture.source)
        _ = try await store.importMaterial(.file(fixture.source, .screenshot), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let board = TestClipboard(.imageData(png, SourceRecord(origin: .clipboard)))
        try await store.setClipboardEnabled(true)
        await ClipboardImportService(gateway: board, store: store).start()
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1)
        XCTAssertEqual(snapshot.materials.first?.source.filePath, fixture.source.path)
        XCTAssertEqual(try Data(contentsOf: fixture.source), png)
    }
    @MainActor
    func testCorruptPreferenceRemainsVisibleAndDoesNotReadClipboard() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        _ = try await store.load()
        let preference = fixture.root.appendingPathComponent("clipboard-settings.json")
        let evidence = Data("损坏的合成设置".utf8)
        try evidence.write(to: preference)
        let board = TestClipboard(.text("不可读取", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start(); await service.poll()
        XCTAssertEqual(service.state, .unavailable)
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(try Data(contentsOf: preference), evidence)
    }
    @MainActor
    func testCurrentTextChangesAndRestartDoNotDuplicate() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = TestClipboard(.text("现有合成文字", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        try await store.setClipboardEnabled(true)
        await service.start()
        var snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1, "Startup must import the existing clipboard")
        await service.poll()
        XCTAssertEqual(board.reads, 1, "Unchanged clipboard must not be repeatedly read")
        board.changeCount += 1
        await service.poll()
        snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1, "Duplicate external copies must not create new cards")
        let restarted = ClipboardImportService(gateway: board, store: MaterialStore(root: fixture.root, budget: fixture.budget))
        await restarted.start()
        snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1)
        XCTAssertEqual(snapshot.materials.first?.source.origin, .clipboard)
    }
    @MainActor
    func testPauseSurvivesRestartAndResumeImportsCurrentContent() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = TestClipboard(.text("第一条", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        try await store.setClipboardEnabled(true)
        await service.start(); await service.setEnabled(false)
        let before = board.reads
        board.changeCount += 1; board.requests = [.text("暂停期间当前内容", SourceRecord(origin: .clipboard))]
        await service.poll()
        XCTAssertEqual(board.reads, before)
        let restarted = ClipboardImportService(gateway: board, store: MaterialStore(root: fixture.root, budget: fixture.budget))
        await restarted.start()
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertEqual(board.reads, before)
        await restarted.setEnabled(true)
        let snapshot = try await store.load()
        // Read the newly saved state through a fresh store, since these are independent instances.
        let disk = try await MaterialStore(root: fixture.root, budget: fixture.budget).load()
        XCTAssertEqual(disk.materials.count, 2)
        XCTAssertEqual(snapshot.materials.count, 1)
    }
    @MainActor
    func testOwnCopiesAndUnstableSnapshotsAreIgnored() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = TestClipboard(.text("不应挂入", SourceRecord(origin: .clipboard)))
        board.isSelfProduced = true
        let service = ClipboardImportService(gateway: board, store: store)
        try await store.setClipboardEnabled(true)
        await service.start()
        board.isSelfProduced = false; board.changeCount += 1; board.mutateWhileReading = true
        await service.poll()
        var snapshot = try await store.load()
        XCTAssertTrue(snapshot.materials.isEmpty)
        board.mutateWhileReading = false
        await service.poll()
        snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1)
    }
    @MainActor
    func testFullPinnedShelfRetainsInputUntilExplicitRetry() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let first = try await store.importMaterial(.text("固定", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        let id = try XCTUnwrap(first.snapshot.materials.first?.id)
        var seed = first.snapshot
        seed.materials[0].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        let pinnedStore = fixture.makeStore()
        let board = TestClipboard(.text("待处理", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: pinnedStore, capacity: { 1 })
        try await store.setClipboardEnabled(true)
        await service.start()
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertEqual(service.state, .pending)
        board.changeCount += 1
        await service.poll()
        XCTAssertEqual(board.reads, 1, "Backpressure must stop reading new clipboard payloads")
        _ = try await pinnedStore.apply(.takeDown(id))
        await service.retryPending()
        let snapshot = try await pinnedStore.load()
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(snapshot.materials.count, 2)
        XCTAssertEqual(snapshot.materials.first?.status, .takenDown)
    }
    @MainActor
    func testHiddenWorkspaceDoesNotReadUntilRevealed() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        var hidden = true
        let board = TestClipboard(.text("隐私合成文本", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store, canRead: { !hidden })
        try await store.setClipboardEnabled(true)
        await service.start()
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(service.state, .hidden)
        hidden = false
        await service.poll()
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1)
    }
}

@MainActor private final class TestClipboard: ClipboardGateway {
    var changeCount = 1
    var reads = 0
    var requests: [ImportRequest]
    var isSelfProduced = false
    var mutateWhileReading = false
    init(_ request: ImportRequest) { requests = [request] }
    func readSnapshot() throws -> ClipboardContents {
        reads += 1
        let revision = changeCount
        if mutateWhileReading { changeCount += 1 }
        return ClipboardContents(revision: revision, isSelfProduced: isSelfProduced, requests: requests)
    }
}
