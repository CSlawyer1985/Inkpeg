import XCTest
@testable import InkpegCore

final class IntakePreferenceTests: XCTestCase {
    @MainActor
    func testPausedManualRetryCanReadCurrentAfterARejectedPaste() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = IntakeBoard(.text(String(repeating: "x", count: ClipboardLimits.textBytes + 1), SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start(); await service.pasteCurrent()
        XCTAssertEqual(service.state, .rejected)
        board.requests = [.text("可重新接收的合成内容", SourceRecord(origin: .clipboard))]; board.changeCount += 1
        await service.retryPending()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
        XCTAssertFalse(service.isEnabled)
    }
    @MainActor
    func testHiddenManualInputDoesNotReadClipboardOrSaveDrop() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let board = IntakeBoard(.text("隐藏中的合成内容", SourceRecord(origin: .clipboard)))
        var hidden = true
        let service = ClipboardImportService(gateway: board, store: store, canRead: { !hidden })
        await service.start(); await service.pasteCurrent(); await service.receive([.file(fixture.source, .drop)])
        let before = try await store.load()
        XCTAssertTrue(before.materials.isEmpty); XCTAssertEqual(board.reads, 0)
        hidden = false; await service.pasteCurrent()
        let after = try await store.load()
        XCTAssertEqual(after.materials.count, 1)
    }
    func testNewWorkspaceDefaultsToManualAndKeepsThatAcrossRestart() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        _ = try await store.load()
        let enabled = try await store.clipboardEnabled()
        XCTAssertFalse(enabled)
        let restarted = fixture.makeStore()
        let afterRestart = try await restarted.clipboardEnabled()
        XCTAssertFalse(afterRestart)
    }
    func testLegacyEnabledSettingAndMissingLegacyDefaultArePreserved() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let original = try await store.load()
        try JSONEncoder().encode(original).write(to: fixture.root.appendingPathComponent("state.json"))
        let legacy = fixture.makeStore()
        let legacySettings = try await legacy.clipboardPreferences()
        XCTAssertTrue(legacySettings.enabled)
        try Data(#"{"version":1,"enabled":false}"#.utf8).write(to: fixture.root.appendingPathComponent("clipboard-settings.json"))
        let paused = try await store.clipboardPreferences()
        XCTAssertFalse(paused.enabled)
        XCTAssertTrue(paused.images && paused.text && paused.files && paused.includeExisting)
    }
    func testPreferencesRoundTripAndUnknownVersionIsPreserved() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let chosen = ClipboardPreference(enabled: true, images: false, text: true, files: false, includeExisting: false)
        try await store.setClipboardPreferences(chosen)
        let actual = try await fixture.makeStore().clipboardPreferences()
        XCTAssertEqual(actual, chosen)
        let evidence = Data(#"{"version":99,"enabled":true}"#.utf8)
        try evidence.write(to: fixture.root.appendingPathComponent("clipboard-settings.json"))
        do { try await store.setClipboardPreferences(chosen); XCTFail("Unknown preferences must not be overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("clipboard-settings.json")), evidence)
    }
    @MainActor
    func testExistingContentCanBeExcludedWhileLaterChangesAreReceived() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        _ = try await store.load()
        try JSONEncoder().encode(ClipboardPreference(enabled: true, includeExisting: false)).write(to: fixture.root.appendingPathComponent("clipboard-settings.json"))
        let board = IntakeBoard(.text("旧内容", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        XCTAssertEqual(board.reads, 0)
        board.changeCount += 1; board.requests = [.text("新内容", SourceRecord(origin: .clipboard))]
        await service.poll()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
        XCTAssertEqual(board.reads, 1)
    }
    @MainActor
    func testAutomaticTypesAreFilteredButExplicitPasteStillWorks() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        _ = try await store.load()
        try JSONEncoder().encode(ClipboardPreference(enabled: true, text: false)).write(to: fixture.root.appendingPathComponent("clipboard-settings.json"))
        let board = IntakeBoard(.text("用户明确粘贴的文字", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        let before = try await store.load()
        XCTAssertTrue(before.materials.isEmpty)
        await service.pasteCurrent()
        let after = try await store.load()
        XCTAssertEqual(after.materials.count, 1)
    }
    @MainActor
    func testPausedAutomaticIntakeAllowsExplicitPasteWithoutEnablingIt() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        _ = try await store.load()
        try Data(#"{"version":1,"enabled":false}"#.utf8).write(to: fixture.root.appendingPathComponent("clipboard-settings.json"))
        let board = IntakeBoard(.text("手动粘贴", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start(); await service.pasteCurrent()
        XCTAssertFalse(service.isEnabled)
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
        XCTAssertEqual(board.reads, 1)
    }
    @MainActor
    func testManualPendingCanRetryWhileAutomaticIntakeIsPaused() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let first = try await store.importMaterial(.text("固定", SourceRecord(origin: .fileSelection)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = first.snapshot; seed.materials[0].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        try Data(#"{"version":1,"enabled":false}"#.utf8).write(to: fixture.root.appendingPathComponent("clipboard-settings.json"))
        let paused = fixture.makeStore(), board = IntakeBoard(.text("空", SourceRecord(origin: .clipboard)))
        let service = ClipboardImportService(gateway: board, store: paused, capacity: { 1 })
        await service.start(); await service.receive([.file(fixture.source, .drop)])
        XCTAssertEqual(service.pendingCount, 1)
        _ = try await paused.apply(.takeDown(try XCTUnwrap(seed.materials.first?.id)))
        await service.retryPending()
        let saved = try await paused.load()
        XCTAssertEqual(saved.materials.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertFalse(service.isEnabled)
    }
}

@MainActor private final class IntakeBoard: ClipboardGateway {
    var changeCount = 1, reads = 0
    var requests: [ImportRequest]
    init(_ request: ImportRequest) { requests = [request] }
    func readSnapshot() throws -> ClipboardContents { reads += 1; return ClipboardContents(revision: changeCount, requests: requests) }
}
