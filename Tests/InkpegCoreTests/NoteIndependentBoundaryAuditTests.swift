import XCTest
@testable import InkpegCore

final class NoteIndependentBoundaryAuditTests: XCTestCase {
    func testPublishRejectsStageDifferentFromDurableDraft() async throws {
        let f = try StoreFixture(), setup = f.makeStore()
        let draft = try await setup.createNoteDraft()
        _ = try await setup.updateNoteDraft(draft.id, text: "author text")
        let store = f.makeStore(files: NoteAuditFiles(.alterStage))
        do {
            _ = try await store.publishNoteDraft(draft.id)
            XCTFail("A changed stage must not publish success or mark the durable draft as published")
        } catch {
            XCTAssertEqual(error as? StoreError, .sourceChanged)
        }
        let snapshot = try await store.load()
        XCTAssertTrue(snapshot.materials.isEmpty)
        let pending = try await store.pendingNoteDrafts()
        XCTAssertEqual(pending.first?.text, "author text")
    }

    func testClearedExistingDraftCanResumeAfterRestart() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "published body")
        _ = try await store.publishNoteDraft(draft.id)
        let edit = try await store.createNoteDraft(for: draft.materialID)
        _ = try await store.updateNoteDraft(edit.id, text: " \n\t")
        let restart = f.makeStore()
        let pending = try await restart.pendingNoteDrafts()
        XCTAssertTrue(pending.contains { $0.id == edit.id && $0.text == " \n\t" }, "A saved clearing edit is still an unpublished draft")
        let resumed = try await restart.createNoteDraft(for: draft.materialID)
        XCTAssertEqual(resumed.id, edit.id)
        XCTAssertEqual(resumed.text, " \n\t")
        do { _ = try await restart.publishNoteDraft(resumed.id); XCTFail("Resuming blank text must not permit publication") }
        catch { XCTAssertEqual(error as? StoreError, .invalidSource) }
    }

    func testLateDraftMarkerFailureRetryKeepsOneCardAndOneVersion() async throws {
        let f = try StoreFixture(), setup = f.makeStore()
        let draft = try await setup.createNoteDraft()
        _ = try await setup.updateNoteDraft(draft.id, text: "late marker")
        let files = NoteAuditFiles(.publishedMarker), failed = f.makeStore(files: files)
        do { _ = try await failed.publishNoteDraft(draft.id); XCTFail("Injected marker write must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let durable = try await f.makeStore().load()
        XCTAssertEqual(durable.materials.count, 1)
        let retry = try await f.makeStore().publishNoteDraft(draft.id)
        XCTAssertEqual(retry.materials.count, 1)
        XCTAssertEqual(retry.materials.first?.id, draft.materialID)
        XCTAssertEqual(retry.materials.first?.versions.count, 1)
        let pending = try await f.makeStore().pendingNoteDrafts()
        XCTAssertTrue(pending.isEmpty)
    }

    func testContentCommittedMarkerFailureRecoversAndRetryIsIdempotent() async throws {
        let f = try StoreFixture(), setup = f.makeStore()
        let draft = try await setup.createNoteDraft()
        _ = try await setup.updateNoteDraft(draft.id, text: "commit marker")
        let failed = f.makeStore(files: NoteAuditFiles(.committedJournal))
        do { _ = try await failed.publishNoteDraft(draft.id); XCTFail("Injected journal write must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let restart = f.makeStore(), recovered = try await restart.load()
        XCTAssertEqual(recovered.materials.first?.id, draft.materialID)
        XCTAssertEqual(recovered.materials.first?.status, .needsReview)
        let retry = try await restart.publishNoteDraft(draft.id)
        XCTAssertEqual(retry.materials.count, 1)
        XCTAssertEqual(retry.materials.first?.versions.count, 1)
        XCTAssertEqual(retry.materials.first?.status, .hanging)
    }

    func testContentMoveFailureKeepsDraftAndCanRetry() async throws {
        let f = try StoreFixture(), setup = f.makeStore()
        let draft = try await setup.createNoteDraft()
        _ = try await setup.updateNoteDraft(draft.id, text: "move failed")
        let failed = f.makeStore(files: NoteAuditFiles(.contentMove))
        do { _ = try await failed.publishNoteDraft(draft.id); XCTFail("Injected move must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let restart = f.makeStore(), snapshot = try await restart.load()
        XCTAssertTrue(snapshot.materials.isEmpty)
        let pending = try await restart.pendingNoteDrafts()
        XCTAssertEqual(pending.first?.id, draft.id)
        let retry = try await restart.publishNoteDraft(draft.id)
        XCTAssertEqual(retry.materials.count, 1)
        XCTAssertEqual(retry.materials.first?.versions.count, 1)
    }

    func testInterruptedExistingEditPreservesOriginalAndRecoversNewText() async throws {
        let f = try StoreFixture(), setup = f.makeStore()
        let draft = try await setup.createNoteDraft()
        _ = try await setup.updateNoteDraft(draft.id, text: "old body")
        let first = try await setup.publishNoteDraft(draft.id), original = try XCTUnwrap(first.materials.first)
        let edit = try await setup.createNoteDraft(for: draft.materialID)
        _ = try await setup.updateNoteDraft(edit.id, text: "new body")
        let failed = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await failed.publishNoteDraft(edit.id); XCTFail("Injected state write must fail") } catch {}
        let restart = f.makeStore(), recovered = try await restart.load()
        XCTAssertEqual(recovered.materials.count, 1)
        XCTAssertEqual(recovered.materials.first?.versions.count, 2)
        let old = try await restart.payloadURL(of: draft.materialID, versionID: original.originalVersionID)
        XCTAssertEqual(try String(contentsOf: old), "old body")
        let retry = try await restart.publishNoteDraft(edit.id)
        XCTAssertEqual(retry.materials.first?.versions.count, 2)
        let current = try await restart.payloadURL(of: draft.materialID)
        XCTAssertEqual(try String(contentsOf: current), "new body")
    }

    func testReturnToPublishedTextDoesNotCreateVersion() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "unchanged")
        _ = try await store.publishNoteDraft(draft.id)
        let edit = try await store.createNoteDraft(for: draft.materialID)
        _ = try await store.updateNoteDraft(edit.id, text: "temporary change")
        _ = try await store.updateNoteDraft(edit.id, text: "unchanged")
        let final = try await store.publishNoteDraft(edit.id)
        XCTAssertEqual(final.materials.first?.versions.count, 1)
        let pending = try await store.pendingNoteDrafts()
        XCTAssertTrue(pending.isEmpty)
    }

    func testUTF8OneMiBBoundaryRejectsExtraByteWithoutChangingSavedDraft() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-audit-limit-" + UUID().uuidString)
        let store = MaterialStore(root: root, budget: StorageBudget(maxFileBytes: 8 * 1024 * 1024, maxMaterialBytes: 16 * 1024 * 1024, minimumFreeBytes: 0))
        let draft = try await store.createNoteDraft(), text = String(repeating: "a", count: ClipboardLimits.textBytes)
        let saved = try await store.updateNoteDraft(draft.id, text: text)
        do { _ = try await store.updateNoteDraft(draft.id, text: text + "b"); XCTFail("Extra byte must be rejected") }
        catch { XCTAssertEqual(error as? StoreError, .budgetExceeded) }
        let restart = MaterialStore(root: root), pending = try await restart.pendingNoteDrafts()
        XCTAssertEqual(pending.first, saved)
    }
}

private struct NoteAuditFiles: FileOperations {
    enum Fault: Sendable { case alterStage, publishedMarker, committedJournal, contentMove }
    let fault: Fault
    let base = SystemFileOperations()
    init(_ fault: Fault) { self.fault = fault }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws {
        if fault == .contentMove && source.pathExtension == "stage" { throw StoreError.unavailableSpace }
        try base.move(source, to: destination)
    }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if fault == .alterStage && url.pathExtension == "stage" {
            try base.writeAtomic(Data(repeating: 120, count: data.count), to: url)
            return
        }
        if fault == .publishedMarker && url.lastPathComponent == "note.json",
           let draft = try? JSONDecoder().decode(NoteDraft.self, from: data), draft.publishedRevision != nil { throw StoreError.unavailableSpace }
        if fault == .committedJournal && url.deletingLastPathComponent().lastPathComponent == "Transactions" && url.pathExtension == "json",
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["phase"] as? String == "contentCommitted" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
