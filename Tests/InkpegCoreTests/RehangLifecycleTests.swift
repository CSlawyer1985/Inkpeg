import XCTest
@testable import InkpegCore

final class RehangLifecycleTests: XCTestCase {
    func testExplicitDragRecognizesSameSourceAcrossIntakeOrigins() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC")!
        for type in 0..<3 {
            let fixture = try StoreFixture(), store = fixture.makeStore()
            let original: ImportRequest = type == 0 ? .text("合成跨入口", SourceRecord(origin: .clipboard)) : type == 1 ? .imageData(png, SourceRecord(origin: .clipboard)) : .file(fixture.source, .fileSelection)
            let dropped: ImportRequest = type == 0 ? .text("合成跨入口", SourceRecord(origin: .drop)) : type == 1 ? .imageData(png, SourceRecord(origin: .drop)) : .file(fixture.source, .drop)
            let first = try await store.importMaterial(original, into: MatterGroup.ungroupedID, visibleCapacity: 3)
            let record = try XCTUnwrap(first.snapshot.materials.first)
            _ = try await store.apply(.takeDown(record.id))
            let result = try await store.importMaterial(dropped, into: MatterGroup.ungroupedID, visibleCapacity: 3, duplicatePolicy: .rehangTakenDown)
            XCTAssertEqual(result.disposition, .hanging(record.id))
            XCTAssertEqual(result.snapshot.materials.count, 1)
            XCTAssertEqual(result.snapshot.materials.first?.source, record.source)
        }
    }

    func testDefaultDuplicatePolicyKeepsTakenDownAndManualPolicyExcludesAuthoredNotes() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let request = ImportRequest.text("合成默认去重", SourceRecord(origin: .clipboard))
        let first = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(first.snapshot.materials.first?.id)
        _ = try await store.apply(.takeDown(id))
        let kept = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertEqual(kept.disposition, .duplicate(id))
        XCTAssertEqual(kept.snapshot.materials.first?.status, .takenDown)
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "原创合成便笺")
        _ = try await store.publishNoteDraft(draft.id)
        _ = try await store.apply(.takeDown(draft.materialID))
        let imported = try await store.importMaterial(.text("原创合成便笺", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 3, deduplicateClipboardContent: true, duplicatePolicy: .rehangTakenDown)
        XCTAssertEqual(imported.snapshot.materials.count, 3)
        XCTAssertEqual(imported.snapshot.materials.first { $0.id == draft.materialID }?.status, .takenDown)
    }
    @MainActor func testManualReimportReusesTextImageAndFileAcrossRestart() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC")!
        for type in 0..<3 {
            let fixture = try StoreFixture(), store = fixture.makeStore()
            let request: ImportRequest = type == 0 ? .text("合成重复文字", SourceRecord(origin: .clipboard)) : type == 1 ? .imageData(png, SourceRecord(origin: .clipboard)) : .file(fixture.source, .clipboard)
            let first = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 3)
            let original = try XCTUnwrap(first.snapshot.materials.first)
            _ = try await store.apply(.takeDown(original.id))
            let restarted = fixture.makeStore(), board = RehangClipboard(request)
            let service = ClipboardImportService(gateway: board, store: restarted)
            await service.start()
            let automatic = try await restarted.load()
            XCTAssertEqual(automatic.materials.count, 1)
            XCTAssertEqual(automatic.materials.first?.status, .takenDown, "Automatic intake must honor take-down")
            await service.receive([request])
            let manual = try await restarted.load()
            XCTAssertEqual(manual.materials.count, 1)
            let restored = try XCTUnwrap(manual.materials.first)
            XCTAssertEqual(restored.status, .hanging, "Explicit reimport should hang the retained material")
            XCTAssertEqual(restored.id, original.id)
            XCTAssertEqual(restored.source, original.source)
            XCTAssertEqual(restored.activeVersionID, original.activeVersionID)
            await service.pasteCurrent()
            let repeated = try await restarted.load()
            XCTAssertEqual(repeated.materials.count, 1)
            let disk = try await fixture.makeStore().load()
            XCTAssertEqual(disk.materials.first?.status, .hanging)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        }
    }

    @MainActor func testReimportKeepsEditedActiveVersionAndOriginalSource() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let request = ImportRequest.text("原始合成文字", SourceRecord(origin: .clipboard))
        let first = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let original = try XCTUnwrap(first.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: original.id, kind: .textEdit)
        try Data("修订后的合成文字".utf8).write(to: session.workingURL)
        let edited = try await store.finishEditing(session, result: .save(session.workingURL))
        let version = try XCTUnwrap(edited.materials.first?.activeVersionID)
        _ = try await store.apply(.takeDown(original.id))
        let service = ClipboardImportService(gateway: RehangClipboard(request), store: store)
        await service.start(); await service.pasteCurrent()
        let restored = try await store.load()
        XCTAssertEqual(restored.materials.first?.status, .hanging)
        XCTAssertEqual(restored.materials.first?.activeVersionID, version)
        XCTAssertEqual(restored.materials.first?.versions.count, 2)
        XCTAssertEqual(restored.materials.first?.source, original.source)
        let payload = try await store.payloadURL(of: original.id)
        XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "修订后的合成文字")
    }

    @MainActor func testArchivedDuplicateRequiresExplicitHang() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let request = ImportRequest.text("合成归档", SourceRecord(origin: .clipboard))
        let first = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 3)
        var seed = first.snapshot; seed.materials[0].status = .archived
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        let restarted = fixture.makeStore(), service = ClipboardImportService(gateway: RehangClipboard(request), store: restarted)
        await service.start(); await service.receive([request])
        let kept = try await restarted.load()
        XCTAssertEqual(kept.materials.first?.status, .archived)
        let hung = try await restarted.apply(.hang(seed.materials[0].id))
        XCTAssertEqual(hung.materials.first?.status, .hanging)
    }

    @MainActor func testManualRehangWaitsForPinnedShelfAndRetainsIdentity() async throws {
        let fixture = try StoreFixture(), store = fixture.makeStore()
        let request = ImportRequest.text("等待挂回", SourceRecord(origin: .clipboard))
        let first = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 1)
        let id = try XCTUnwrap(first.snapshot.materials.first?.id)
        _ = try await store.apply(.takeDown(id))
        let blocker = try await store.importMaterial(.text("固定合成卡片", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        var seed = blocker.snapshot
        let index = try XCTUnwrap(seed.materials.firstIndex { $0.status == .hanging }); seed.materials[index].pinned = true
        try JSONEncoder().encode(seed).write(to: fixture.root.appendingPathComponent("state.json"), options: .atomic)
        let restarted = fixture.makeStore(), service = ClipboardImportService(gateway: RehangClipboard(request), store: restarted, capacity: { 1 })
        await service.start(); await service.receive([request])
        XCTAssertEqual(service.pendingCount, 1)
        let blocked = try await restarted.load()
        XCTAssertEqual(blocked.materials.first { $0.id == id }?.status, .takenDown)
        _ = try await restarted.apply(.takeDown(seed.materials[index].id))
        await service.retryPending()
        XCTAssertEqual(service.pendingCount, 0)
        let restored = try await restarted.load()
        XCTAssertEqual(restored.materials.count, 2)
        XCTAssertEqual(restored.materials.first { $0.id == id }?.status, .hanging)
    }
}

@MainActor private final class RehangClipboard: ClipboardGateway {
    var changeCount = 1
    let request: ImportRequest
    init(_ request: ImportRequest) { self.request = request }
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: changeCount, requests: [request]) }
}
