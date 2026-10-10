import Foundation
import XCTest
@testable import InkpegCore

final class FinalCoreFailureRetryAuditTests: XCTestCase {
    func testChangedWorkingCopyAfterFailedSaveAndCloseMustRemainPending() async throws {
        let f = try StoreFixture(), normal = f.makeStore()
        let original = try await normal.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(original.snapshot.materials.first)
        let session = try await normal.createDerivedVersion(of: record.id, kind: .textEdit)
        let failed = f.makeStore(files: FaultFiles(.snapshotWrite))
        try await failed.writeEditingResult(session, data: Data("earlier attempted save".utf8))
        do { _ = try await failed.finishEditing(session, result: .save(session.workingURL)); XCTFail("Injected save must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let latest = Data("latest draft before close".utf8)
        try await failed.writeEditingResult(session, data: latest)
        _ = try await failed.finishEditing(session, result: .cancel)
        let restart = f.makeStore()
        let pending = try await restart.pendingEditSessions()
        XCTAssertTrue(pending.contains { $0.id == session.id }, "A later autosaved draft must remain recoverable after closing a failed save")
        XCTAssertEqual(try Data(contentsOf: session.workingURL), latest)
    }

    func testLatestWorkingCopySurvivesRetryJournalWriteFailure() async throws {
        let f = try StoreFixture(), normal = f.makeStore()
        let original = try await normal.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(original.snapshot.materials.first)
        let session = try await normal.createDerivedVersion(of: record.id, kind: .textEdit)
        let fault = AuditRetryJournalFault(), failed = f.makeStore(files: fault)
        try await failed.writeEditingResult(session, data: Data("earlier attempted save".utf8))
        do { _ = try await failed.finishEditing(session, result: .save(session.workingURL)); XCTFail("Injected save must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let latest = Data("latest draft before journal failure".utf8)
        try await failed.writeEditingResult(session, data: latest)
        fault.armJournalFailure()
        do { _ = try await failed.finishEditing(session, result: .save(session.workingURL)); XCTFail("Injected journal write must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let restart = f.makeStore()
        let pending = try await restart.pendingEditSessions()
        XCTAssertTrue(pending.contains { $0.id == session.id }, "The previous transaction must not hide a newer working copy when its next journal write fails")
        XCTAssertEqual(try Data(contentsOf: session.workingURL), latest)
    }

    @MainActor func testNewRevisionPrepareBusyRemainsEligibleForNextPoll() async throws {
        let f = try StoreFixture(), files = AuditCoreCopyGate()
        let store = f.makeStore(files: files)
        try await store.setClipboardPreferences(ClipboardPreference(enabled: true, includeExisting: false))
        let board = AuditCoreClipboardBoard(), service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        let other = f.source.deletingLastPathComponent().appendingPathComponent("other.txt")
        try Data("unrelated explicit import".utf8).write(to: other)
        files.arm()
        var importTask: Task<ImportResult, Error>?
        board.changeCount += 1
        board.requests = [.file(f.source, .clipboard)]
        board.onRead = {
            importTask = Task.detached { try await store.importMaterial(.file(other, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3) }
            XCTAssertTrue(files.waitForCopy())
        }
        await service.poll()
        files.releaseCopy()
        _ = try await XCTUnwrap(importTask).value
        await service.poll()
        let snapshot = try await store.load()
        XCTAssertEqual(board.reads, 2, "A new revision rejected by temporary store contention must be read again")
        XCTAssertEqual(snapshot.materials.count, 2)
    }

    @MainActor func testStoreBusyMustNotEnableExcludedExistingClipboard() async throws {
        let f = try StoreFixture()
        let files = AuditCoreCopyGate()
        let store = f.makeStore(files: files)
        try await store.setClipboardPreferences(ClipboardPreference(enabled: true, includeExisting: false))
        let board = AuditCoreClipboardBoard()
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        XCTAssertEqual(board.reads, 0)
        files.arm()
        let importTask = Task { try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3) }
        let entered = await Task.detached { files.waitForCopy() }.value
        XCTAssertTrue(entered)
        await service.poll()
        files.releaseCopy()
        _ = try await importTask.value
        await service.poll()
        XCTAssertEqual(board.reads, 0, "A temporary busy store must not override includeExisting=false")
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 1, "Only the explicit file import should have been saved")
    }

    func testRepeatedFailedImportMustNotRecoverDuplicateCards() async throws {
        let f = try StoreFixture()
        let store = f.makeStore(files: FaultFiles(.snapshotWrite))
        do {
            _ = try await store.importMaterial(.file(f.source, .clipboard), into: MatterGroup.ungroupedID, visibleCapacity: 3, deduplicateClipboardContent: true)
            XCTFail("Initial injected snapshot write must fail")
        } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let journals = try SystemFileOperations().list(f.root.appendingPathComponent("Transactions")).filter { $0.pathExtension == "json" }
        let initialJournal = try JSONDecoder().decode(StoreJournal.self, from: Data(contentsOf: XCTUnwrap(journals.first)))
        // A retry may acknowledge the already durable journal without writing another
        // snapshot, or may attempt a snapshot write and surface the injected failure.
        // Both outcomes must preserve exactly the initial material UUID.
        do {
            let retried = try await store.importMaterial(.file(f.source, .clipboard), into: MatterGroup.ungroupedID, visibleCapacity: 3, deduplicateClipboardContent: true)
            XCTAssertEqual(retried.snapshot.materials.count, 1)
            XCTAssertEqual(retried.snapshot.materials.first?.id, initialJournal.record.id)
        } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let restarted = try await f.makeStore().load()
        XCTAssertEqual(restarted.materials.count, 1, "Retry of one pending clipboard input must recover only one card")
        XCTAssertEqual(restarted.materials.first?.id, initialJournal.record.id)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testRepeatedFailedDerivedSavesMustKeepLatestTextRecoverable() async throws {
        let f = try StoreFixture()
        let normal = f.makeStore()
        let original = try await normal.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(original.snapshot.materials.first)
        let session = try await normal.createDerivedVersion(of: record.id, kind: .textEdit)
        let failed = f.makeStore(files: FaultFiles(.snapshotWrite))
        let earlier = Data("earlier failed save".utf8)
        let latest = Data("latest failed save".utf8)
        for bytes in [earlier, latest] {
            try await failed.writeEditingResult(session, data: bytes)
            do {
                _ = try await failed.finishEditing(session, result: .save(session.workingURL))
                XCTFail("Injected snapshot write must fail")
            } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        }
        let restart = f.makeStore(files: OldestJournalFirstFiles())
        let recovered = try await restart.load()
        let active = try await restart.payloadURL(of: record.id)
        let sessions = try await restart.pendingEditSessions()
        let latestIsActive = try Data(contentsOf: active) == latest
        XCTAssertTrue(latestIsActive || sessions.contains(session), "Latest durable working copy must be reachable through the active version or pending session")
        XCTAssertEqual(recovered.materials.first?.status, .needsReview)
        XCTAssertEqual(try Data(contentsOf: session.workingURL), latest)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
}

@MainActor private final class AuditCoreClipboardBoard: ClipboardGateway {
    var changeCount = 7
    var reads = 0
    var requests: [ImportRequest] = [.text("existing clipboard intentionally excluded", SourceRecord(origin: .clipboard))]
    var onRead: (() -> Void)?
    func readSnapshot() throws -> ClipboardContents {
        reads += 1
        let callback = onRead; onRead = nil; callback?()
        return ClipboardContents(revision: changeCount, requests: requests)
    }
}

private final class AuditRetryJournalFault: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    private let lock = NSLock()
    private var rejectJournal = false
    func armJournalFailure() { lock.lock(); rejectJournal = true; lock.unlock() }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws {
        lock.lock(); let failJournal = rejectJournal; lock.unlock()
        if destination.lastPathComponent == "state.json" || (failJournal && destination.deletingLastPathComponent().lastPathComponent == "Transactions" && destination.pathExtension == "json") { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: destination)
    }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func trash(_ url: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
}

private final class AuditCoreCopyGate: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    private let lock = NSLock(), entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func waitForCopy() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func releaseCopy() { released.signal() }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws {
        lock.lock(); let block = armed; if block { armed = false }; lock.unlock()
        if block {
            entered.signal()
            guard released.wait(timeout: .now() + 4) == .success else { throw StoreError.operationInProgress }
        }
        try base.copy(source, to: destination)
    }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws { try base.writeAtomic(data, to: destination) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func trash(_ url: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
}

private struct OldestJournalFirstFiles: FileOperations {
    let base = SystemFileOperations()
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws { try base.writeAtomic(data, to: destination) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func trash(_ url: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ url: URL) throws -> [URL] {
        let values = try base.list(url)
        guard url.lastPathComponent == "Transactions" else { return values }
        return values.sorted { left, right in
            let a = (try? JSONDecoder().decode(StoreJournal.self, from: base.read(left)))?.record.activeVersion?.createdAt ?? .distantPast
            let b = (try? JSONDecoder().decode(StoreJournal.self, from: base.read(right)))?.record.activeVersion?.createdAt ?? .distantPast
            return a < b
        }
    }
}
