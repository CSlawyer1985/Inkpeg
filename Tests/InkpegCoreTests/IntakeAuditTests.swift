import XCTest
@testable import InkpegCore

final class IntakeAuditTests: XCTestCase {
    @MainActor func testFileSelectionKeepsChosenSourceAndSavesThroughManualQueue() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = AuditClipboard(.text("unrelated clipboard", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start(); await service.receive([.file(fixture.source, .fileSelection)])
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
        XCTAssertEqual(saved.materials.first?.source.origin, .fileSelection)
        XCTAssertEqual(saved.materials.first?.source.filePath, fixture.source.path)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
    @MainActor
    func testManualPendingRetryMustKeepExcludedCurrentClipboardExcluded() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let first = try await store.importMaterial(.text("pinned", SourceRecord(origin: .fileSelection)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = first.snapshot; seed.materials[0].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        try await store.setClipboardPreferences(ClipboardPreference(enabled: true, includeExisting: false))
        let restarted = fixture.makeStore(), board = AuditClipboard(.text("excluded startup clipboard", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: restarted, capacity: { 1 })
        await service.start()
        XCTAssertEqual(board.reads, 0)
        await service.receive([.file(fixture.source, .drop)])
        XCTAssertEqual(service.pendingCount, 1)
        _ = try await restarted.apply(.takeDown(seed.materials[0].id))
        await service.retryPending()
        let saved = try await restarted.load()
        XCTAssertEqual(saved.materials.count, 2, "Retry should save only the explicitly dropped material")
        XCTAssertEqual(board.reads, 0, "Retry must not read an unchanged excluded clipboard")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
}

@MainActor private final class AuditClipboard: ClipboardGateway {
    var changeCount = 1, reads = 0
    var requests: [ImportRequest]
    init(_ request: ImportRequest) { requests = [request] }
    func readSnapshot() throws -> ClipboardContents {
        reads += 1; return ClipboardContents(revision: changeCount, requests: requests)
    }
}
