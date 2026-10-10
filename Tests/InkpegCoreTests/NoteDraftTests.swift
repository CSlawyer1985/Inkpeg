import XCTest
@testable import InkpegCore

final class NoteDraftTests: XCTestCase {
    func testChangedStagingBytesCannotBecomePublishedNote() async throws {
        let f = try StoreFixture(), store = f.makeStore(files: ChangedNoteStageFiles())
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "应完整保留的记事正文")
        do { _ = try await store.publishNoteDraft(draft.id); XCTFail("Changed staging content must be rejected before publishing") }
        catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
        let after = try await store.load(); XCTAssertTrue(after.materials.isEmpty)
        let pending = try await store.pendingNoteDrafts(); XCTAssertEqual(pending.first?.text, "应完整保留的记事正文")
    }
    func testAuthoredOriginIsTruthfulAndImportedMatchingTextStaysAnExcerpt() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let one = try await store.createNoteDraft(), two = try await store.createNoteDraft()
        for draft in [one, two] { _ = try await store.updateNoteDraft(draft.id, text: "相同正文各自记事"); _ = try await store.publishNoteDraft(draft.id, visibleCapacity: 3) }
        let imported = try await store.importMaterial(.text("相同正文各自记事", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3, deduplicateClipboardContent: true)
        XCTAssertEqual(imported.snapshot.materials.count, 3)
        XCTAssertEqual(imported.snapshot.materials.filter { $0.source.origin == .note }.count, 2)
        XCTAssertEqual(imported.snapshot.materials.filter { $0.source.origin == .clipboard }.count, 1)
        XCTAssertEqual(SourceFormatter.describe(SourceRecord(origin: .note), localizer: Localizer(localeIdentifier: "zh-Hans")), "自己写的记事")
    }
    func testAutosavedDraftSurvivesRestartWithoutHanging() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        let saved = try await store.updateNoteDraft(draft.id, text: "第一行中文\n第二行完整正文")
        XCTAssertEqual(saved.revision, 1)
        let reopened = f.makeStore()
        let pending = try await reopened.pendingNoteDrafts()
        XCTAssertEqual(pending, [saved])
        let workspace = try await reopened.load(); XCTAssertTrue(workspace.materials.isEmpty)
        let importedDrafts = try await reopened.pendingEditSessions(); XCTAssertTrue(importedDrafts.isEmpty)
    }
    func testBlankDraftIsRetainedButCannotPublish() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: " \n\t")
        do { _ = try await store.publishNoteDraft(draft.id); XCTFail("Blank note must not hang") }
        catch { XCTAssertEqual(error as? StoreError, .invalidSource) }
        let workspace = try await store.load(); XCTAssertTrue(workspace.materials.isEmpty)
        let again = try await store.updateNoteDraft(draft.id, text: "正文仍可继续"); XCTAssertEqual(again.text, "正文仍可继续")
    }
    func testPublishIsIdempotentAndFirstLineBecomesTitle() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: " 标题第一行 \n下一行正文")
        let first = try await store.publishNoteDraft(draft.id)
        let second = try await store.publishNoteDraft(draft.id)
        XCTAssertEqual(first.materials, second.materials)
        XCTAssertEqual(second.materials.count, 1)
        let note = try XCTUnwrap(second.materials.first)
        XCTAssertEqual(note.id, draft.materialID); XCTAssertEqual(note.source.origin, .note)
        XCTAssertEqual(note.title, "标题第一行"); XCTAssertEqual(note.versions.count, 1)
        let url = try await store.payloadURL(of: note.id)
        XCTAssertEqual(try String(contentsOf: url), " 标题第一行 \n下一行正文")
        let pending = try await store.pendingNoteDrafts(); XCTAssertTrue(pending.isEmpty)
    }
    func testEditingKeepsTheSameCardAndPreservesImportedExcerpt() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "记事原稿")
        let first = try await store.publishNoteDraft(draft.id), note = try XCTUnwrap(first.materials.first)
        let edit = try await store.createNoteDraft(for: note.id)
        _ = try await store.updateNoteDraft(edit.id, text: "记事修改稿")
        let next = try await store.publishNoteDraft(edit.id), updated = try XCTUnwrap(next.materials.first)
        XCTAssertEqual(updated.id, note.id); XCTAssertEqual(updated.versions.count, 2)
        let original = try await store.payloadURL(of: note.id, versionID: note.originalVersionID)
        XCTAssertEqual(try String(contentsOf: original), "记事原稿")
        let imported = try await store.importMaterial(.text("导入摘录", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let excerpt = try XCTUnwrap(imported.snapshot.materials.first { $0.source.origin == .clipboard })
        do { _ = try await store.createNoteDraft(for: excerpt.id); XCTFail("Imported excerpts are not authored notes") }
        catch { XCTAssertEqual(error as? StoreError, .invalidEdit) }
        let unchanged = try await store.load().materials.first { $0.id == excerpt.id }
        XCTAssertEqual(unchanged, excerpt)
    }
    func testInterruptedSnapshotWriteRecoversOneCardAndRetryDoesNotDuplicate() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "中断时保留的记事")
        let failing = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await failing.publishNoteDraft(draft.id); XCTFail("Injected snapshot failure must report") } catch {}
        let recovered = f.makeStore()
        let snapshot = try await recovered.load()
        XCTAssertEqual(snapshot.materials.count, 1)
        XCTAssertEqual(snapshot.materials.first?.id, draft.materialID)
        XCTAssertEqual(snapshot.materials.first?.status, .needsReview)
        let retry = try await recovered.publishNoteDraft(draft.id)
        XCTAssertEqual(retry.materials.count, 1); XCTAssertEqual(retry.materials.first?.versions.count, 1)
        XCTAssertEqual(retry.materials.first?.status, .hanging)
        let pending = try await recovered.pendingNoteDrafts(); XCTAssertTrue(pending.isEmpty)
    }
    func testStaleEditCannotOverwriteAnotherSavedVersion() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "共同基稿")
        let published = try await store.publishNoteDraft(draft.id)
        let note = try XCTUnwrap(published.materials.first)
        let one = try await store.createNoteDraft(for: note.id), two = try await store.createNoteDraft(for: note.id)
        _ = try await store.updateNoteDraft(one.id, text: "先保存的正文")
        _ = try await store.updateNoteDraft(two.id, text: "过期正文不得覆盖")
        _ = try await store.publishNoteDraft(one.id)
        do { _ = try await store.publishNoteDraft(two.id); XCTFail("Stale draft must remain separate") }
        catch { XCTAssertEqual(error as? StoreError, .invalidEdit) }
        let current = try await store.payloadURL(of: note.id)
        XCTAssertEqual(try String(contentsOf: current), "先保存的正文")
        let pending = try await store.pendingNoteDrafts(); XCTAssertTrue(pending.contains { $0.id == two.id && $0.text == "过期正文不得覆盖" })
    }
    func testFullPinnedShelfRetainsUnpublishedDraft() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        var snapshot = WorkspaceSnapshot()
        for i in 0..<3 { snapshot = try await store.importMaterial(.text("固定合成材料\(i)", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot }
        for i in snapshot.materials.indices { snapshot.materials[i].pinned = true }
        try JSONEncoder().encode(snapshot).write(to: f.root.appendingPathComponent("state.json"), options: .atomic)
        let current = f.makeStore(), draft = try await current.createNoteDraft()
        _ = try await current.updateNoteDraft(draft.id, text: "架满保留记事")
        do { _ = try await current.publishNoteDraft(draft.id, visibleCapacity: 3); XCTFail("Pinned cards must not fall") }
        catch { XCTAssertEqual(error as? StoreError, .budgetExceeded) }
        let after = try await current.load(); XCTAssertEqual(after.materials, snapshot.materials)
        let pending = try await current.pendingNoteDrafts(); XCTAssertTrue(pending.contains { $0.id == draft.id })
    }
}

private struct ChangedNoteStageFiles: FileOperations {
    let base = SystemFileOperations()
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        try base.writeAtomic(data, to: url)
        if url.pathExtension == "stage" { try base.writeAtomic(Data("改变过的合成暂存正文".utf8), to: url) }
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
