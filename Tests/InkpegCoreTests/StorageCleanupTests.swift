import XCTest
@testable import InkpegCore

final class StorageCleanupTests: XCTestCase {
    func testPreviewProtectsHangingPinnedReviewDraftsAndRecentExports() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        var ids = [UUID]()
        for text in ["hanging", "pinned", "review", "draft", "eligible"] {
            let r = try await store.importMaterial(.text(text, SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
            if case .hanging(let id) = r.disposition { ids.append(id) }
        }
        var snapshot = try await store.load()
        for index in snapshot.materials.indices {
            if snapshot.materials[index].id != ids[0] { snapshot.materials[index].status = .takenDown }
            if snapshot.materials[index].id == ids[1] { snapshot.materials[index].pinned = true }
            if snapshot.materials[index].id == ids[2] { snapshot.materials[index].status = .needsReview }
        }
        try JSONEncoder().encode(snapshot).write(to: f.root.appendingPathComponent("state.json"))
        let reopened = f.makeStore(files: files)
        _ = try await reopened.createNoteDraft(for: ids[3])
        let old = f.root.appendingPathComponent("Exports/old/Inkpeg.txt"), recent = f.root.appendingPathComponent("Exports/recent/Inkpeg.txt")
        _ = try await reopened.exportCopy(of: ids[0], to: old)
        _ = try await reopened.exportCopy(of: ids[0], to: recent)
        try age(old); try age(old.deletingLastPathComponent())
        let before = try Data(contentsOf: f.root.appendingPathComponent("state.json"))
        let plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(plan.materialCount, 1); XCTAssertEqual(plan.exportCount, 1)
        XCTAssertEqual(plan.targets.first(where: { $0.kind == .material })?.materialID, ids[4])
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.json")), before, "Preview is read-only")
        XCTAssertTrue(files.trashCalls.isEmpty)
    }

    func testCleanupMovesCopiesToTrashPreservesOriginalAndSurvivesRestart() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let payload = try await store.payloadURL(of: id)
        _ = try await store.apply(.takeDown(id))
        let plan = try await store.previewStorageCleanup()
        XCTAssertEqual(plan.materialCount, 1)
        let result = try await store.cleanStorage(plan)
        XCTAssertEqual(result.movedCount, 1); XCTAssertEqual(result.failedCount, 0); XCTAssertEqual(result.unverifiedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        XCTAssertEqual(files.trashCalls.count, 1)
        XCTAssertEqual(try Data(contentsOf: files.trashCalls[0].1.appendingPathComponent(payload.lastPathComponent)), f.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.receiptURL.path))
        let restarted = try await f.makeStore(files: files).load()
        XCTAssertEqual(restarted.materials.first?.status, .trashed)
        let remaining = try await f.makeStore(files: files).previewStorageCleanup()
        XCTAssertTrue(remaining.targets.isEmpty)
    }

    func testStalePreviewCannotCleanNewlyRehangedMaterial() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        let r = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(r.snapshot.materials.first?.id)
        _ = try await store.apply(.takeDown(id)); let plan = try await store.previewStorageCleanup()
        _ = try await store.apply(.hang(id))
        do { _ = try await store.cleanStorage(plan); XCTFail("Stale approval must be refused") } catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
        XCTAssertTrue(files.trashCalls.isEmpty)
        _ = try await store.payloadURL(of: id)
    }

    func testTrashFailureKeepsPayloadAndRestoresTakenDownStatus() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        let r = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(r.snapshot.materials.first?.id), payload = try await store.payloadURL(of: id)
        _ = try await store.apply(.takeDown(id)); let plan = try await store.previewStorageCleanup()
        files.failTrash = true
        let result = try await store.cleanStorage(plan)
        XCTAssertEqual(result.failedCount, 1); XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.snapshot.materials.first?.status, .takenDown)
        XCTAssertEqual(try Data(contentsOf: payload), f.bytes)
        files.failTrash = false
        let retry = try await store.previewStorageCleanup()
        let retried = try await store.cleanStorage(retry)
        XCTAssertEqual(retried.movedCount, 1)
    }

    func testStateWriteFailureNeverStartsTrashing() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        let r = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(r.snapshot.materials.first?.id), payload = try await store.payloadURL(of: id)
        _ = try await store.apply(.takeDown(id)); let plan = try await store.previewStorageCleanup()
        files.failStateWrite = true
        do { _ = try await store.cleanStorage(plan); XCTFail("State must be durable before moving content") } catch {}
        XCTAssertTrue(files.trashCalls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: payload), f.bytes)
    }

    func testChangedExportAndSymlinkAreNeverTrashed() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        let old = f.root.appendingPathComponent("Exports/old.txt")
        try Data("old".utf8).write(to: old); try age(old)
        let plan = try await store.previewStorageCleanup()
        try Data("modified externally".utf8).write(to: old)
        do { _ = try await store.cleanStorage(plan); XCTFail("Changed export cannot use old approval") } catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
        let link = f.root.appendingPathComponent("Exports/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        do { _ = try await store.previewStorageCleanup(); XCTFail("Symlink must fail closed") } catch {}
        XCTAssertTrue(files.trashCalls.isEmpty); XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testSecondStateWriteFailureCanRetryAfterRestart() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        let r = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(r.snapshot.materials.first?.id), payload = try await store.payloadURL(of: id)
        _ = try await store.apply(.takeDown(id)); let plan = try await store.previewStorageCleanup()
        files.stateWritesUntilFailure = 2
        do { _ = try await store.cleanStorage(plan); XCTFail("Interrupted persistence must stop before Trash") } catch {}
        XCTAssertTrue(files.trashCalls.isEmpty); XCTAssertEqual(try Data(contentsOf: payload), f.bytes)
        let reopened = f.makeStore(files: files), retry = try await reopened.previewStorageCleanup()
        XCTAssertEqual(retry.materialCount, 1)
        let result = try await reopened.cleanStorage(retry)
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testMovedButUnverifiedTrashNeverClaimsSuccessOrResurrects() async throws {
        for mode in [CleanupTestFiles.TrashFault.throwAfterMove, .unknownDestination] {
            let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
            let r = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            let id = try XCTUnwrap(r.snapshot.materials.first?.id)
            _ = try await store.apply(.takeDown(id)); let plan = try await store.previewStorageCleanup()
            files.trashFault = mode
            let result = try await store.cleanStorage(plan)
            XCTAssertEqual(result.movedCount, 0); XCTAssertEqual(result.unverifiedCount, 1)
            XCTAssertEqual(result.snapshot.materials.first?.status, .trashed)
            XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
            let reopened = f.makeStore(files: files)
            let snapshot = try await reopened.load(), retry = try await reopened.previewStorageCleanup()
            XCTAssertEqual(snapshot.materials.first?.status, .trashed); XCTAssertTrue(retry.targets.isEmpty)
            let receipt = try JSONDecoder().decode(CleanupReceipt.self, from: Data(contentsOf: result.receiptURL))
            XCTAssertEqual(receipt.outcomes.first?.verified, false)
        }
    }

    func testReceiptFailureLeavesUnmovedCopiesRetryableAfterRestart() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        for text in ["first", "second"] {
            let r = try await store.importMaterial(.text(text, SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            let id = try XCTUnwrap(r.snapshot.materials.first(where: { $0.title == text })?.id)
            _ = try await store.apply(.takeDown(id))
        }
        let plan = try await store.previewStorageCleanup()
        XCTAssertEqual(plan.materialCount, 2)
        files.receiptWritesUntilFailure = 2
        do { _ = try await store.cleanStorage(plan); XCTFail("Audit write failure stops further moves") } catch {}
        XCTAssertEqual(files.trashCalls.count, 1)
        let reopened = f.makeStore(files: files), retry = try await reopened.previewStorageCleanup()
        XCTAssertEqual(retry.materialCount, 1)
        let result = try await reopened.cleanStorage(retry)
        XCTAssertEqual(result.movedCount, 1)
        let snapshot = try await f.makeStore(files: files).load()
        XCTAssertTrue(snapshot.materials.allSatisfy { $0.status == .trashed })
        XCTAssertEqual(files.trashCalls.count, 2)
    }

    func testUnknownDraftFilesBlockCleanupWithoutMovingAnything() async throws {
        let f = try StoreFixture(), files = CleanupTestFiles(), store = f.makeStore(files: files)
        let r = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(r.snapshot.materials.first?.id)
        _ = try await store.apply(.takeDown(id))
        let draft = try await store.createNoteDraft()
        let folder = f.root.appendingPathComponent("Drafts/" + draft.id.uuidString)
        try Data("recovery content".utf8).write(to: folder.appendingPathComponent("unknown.txt"))
        do { _ = try await store.previewStorageCleanup(); XCTFail("Unknown recovery files must fail closed") } catch { XCTAssertEqual(error as? StoreError, .recoveryRequired) }
        XCTAssertTrue(files.trashCalls.isEmpty)
    }

    private func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: url.path)
    }
}

private final class CleanupTestFiles: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    var failTrash = false, failStateWrite = false
    enum TrashFault { case throwAfterMove, unknownDestination }
    var trashFault: TrashFault?
    var stateWritesUntilFailure: Int?, receiptWritesUntilFailure: Int?
    var trashCalls: [(URL, URL)] = []
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func writeAtomic(_ data: Data, to destination: URL) throws {
        if failStateWrite && destination.lastPathComponent == "state.json" { throw StoreError.unavailableSpace }
        if destination.lastPathComponent == "state.json", let remaining = stateWritesUntilFailure {
            stateWritesUntilFailure = remaining == 1 ? nil : remaining - 1
            if remaining == 1 { throw StoreError.unavailableSpace }
        }
        if destination.deletingLastPathComponent().lastPathComponent == "CleanupRecords", let remaining = receiptWritesUntilFailure {
            receiptWritesUntilFailure = remaining == 1 ? nil : remaining - 1
            if remaining == 1 { throw StoreError.unavailableSpace }
        }
        try base.writeAtomic(data, to: destination)
    }
    func trash(_ source: URL) throws -> URL {
        if failTrash { throw StoreError.unavailableSpace }
        let simulatedTrash = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("simulated-trash")
        try base.createDirectory(simulatedTrash)
        let destination = simulatedTrash.appendingPathComponent(UUID().uuidString)
        try base.move(source, to: destination); trashCalls.append((source, destination))
        if trashFault == .throwAfterMove { throw StoreError.unavailableSpace }
        if trashFault == .unknownDestination { return simulatedTrash.appendingPathComponent("unknown") }
        return destination
    }
}
