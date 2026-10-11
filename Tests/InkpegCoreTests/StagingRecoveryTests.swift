import XCTest
@testable import InkpegCore

final class StagingRecoveryTests: XCTestCase {
    func testFailedJournalsFillTwelveByteBudgetUntilExplicitCleanup() async throws {
        let f = try StoreFixture(), files = StagingTestFiles()
        try Data("base".utf8).write(to: f.source)
        let store = MaterialStore(root: f.root, files: files, budget: StorageBudget(maxFileBytes: 12, maxMaterialBytes: 12, minimumFreeBytes: 0))
        let committed = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 4)
        let id = try XCTUnwrap(committed.snapshot.materials.first?.id), payload = try await store.payloadURL(of: id)
        files.failJournal = true
        for text in ["one!", "two!"] {
            do { _ = try await store.importMaterial(.text(text, SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 4); XCTFail("Journal fault accepted") } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        }
        files.failJournal = false
        do { _ = try await store.importMaterial(.text("next", SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 4); XCTFail("Failed staging must remain charged") } catch { XCTAssertEqual(error as? StoreError, .budgetExceeded) }
        let reopened = MaterialStore(root: f.root, files: files, budget: StorageBudget(maxFileBytes: 12, maxMaterialBytes: 12, minimumFreeBytes: 0))
        let plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(stages(plan).count, 2); XCTAssertEqual(plan.byteCount, 8)
        XCTAssertEqual(try files.list(f.root.appendingPathComponent("Transactions")).filter { $0.pathExtension == "stage" }.count, 2, "Restart/preview must never auto-delete")
        let retained = f.source.deletingLastPathComponent().appendingPathComponent("retained-at-full-budget.txt")
        _ = try await reopened.exportStagingCopy(try XCTUnwrap(stages(plan).first), from: plan, to: retained)
        XCTAssertEqual(try Data(contentsOf: retained).count, 4, "Library quota must not block retention export outside the library")
        let result = try await reopened.cleanStorage(plan)
        XCTAssertEqual(result.movedCount, 2); XCTAssertEqual(result.movedBytes, 8)
        XCTAssertEqual(try Data(contentsOf: f.source), Data("base".utf8)); XCTAssertEqual(try Data(contentsOf: payload), Data("base".utf8))
        let next = try await reopened.importMaterial(.text("next", SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 4)
        XCTAssertEqual(next.snapshot.materials.count, 2)
    }

    func testFailureBeforeStageLeavesNoCandidates() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(); files.failBeforeStage = true
        let store = f.makeStore(files: files)
        do { _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 4); XCTFail("Copy fault accepted") } catch {}
        let plan = try await store.previewStorageCleanup(); XCTAssertTrue(stages(plan).isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testFailureAfterStageWithoutJournalIsExplicitCandidate() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(); files.failAfterStage = true
        let store = f.makeStore(files: files)
        do { _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 4); XCTFail("After-stage fault accepted") } catch {}
        let plan = try await store.previewStorageCleanup(); XCTAssertEqual(stages(plan).count, 1); XCTAssertEqual(plan.byteCount, Int64(f.bytes.count))
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testExistingJournalProtectsUncommittedStagingAfterRestart() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(); files.failCommit = true
        let store = f.makeStore(files: files)
        do { _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 4); XCTFail("Commit fault accepted") } catch {}
        let plan = try await f.makeStore(files: files).previewStorageCleanup(); XCTAssertTrue(stages(plan).isEmpty)
        XCTAssertEqual(try files.list(f.root.appendingPathComponent("Transactions")).filter { $0.pathExtension == "stage" }.count, 1)
    }

    func testVerifiedSameContentStageCanCleanWithoutAffectingCommittedCopy() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 4)
        files.failJournal = true
        do { _ = try await store.importMaterial(.text(try XCTUnwrap(String(data: f.bytes, encoding: .utf8)), SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 4); XCTFail("Same-content journal failure must surface") } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        files.failJournal = false
        try Data("unknown".utf8).write(to: f.root.appendingPathComponent("Transactions/unknown.stage"))
        try Data("evidence".utf8).write(to: f.root.appendingPathComponent("Transactions/unknown.bin"))
        let plan = try await store.previewStorageCleanup(); XCTAssertEqual(stages(plan).count, 1)
        XCTAssertEqual(plan.stagingInventory.filter { $0.disposition == .needsInspection }.count, 2)
        let snapshot = try await store.load()
        let payload = try await store.payloadURL(of: try XCTUnwrap(snapshot.materials.first?.id))
        _ = try await store.cleanStorage(plan)
        XCTAssertEqual(try Data(contentsOf: payload), f.bytes); XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        XCTAssertEqual(try files.list(f.root.appendingPathComponent("Transactions")).filter { $0.lastPathComponent.hasPrefix("unknown") }.count, 2)
    }

    func testStageChangedAfterPreviewRefusesTrash() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        let stage = f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")
        try Data("old".utf8).write(to: stage)
        let plan = try await store.previewStorageCleanup(); XCTAssertEqual(stages(plan).count, 1)
        try Data("new".utf8).write(to: stage)
        do { _ = try await store.cleanStorage(plan); XCTFail("Changed evidence cannot use old approval") } catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
        XCTAssertTrue(files.trashCalls.isEmpty)
    }

    func testPartialTrashFailureRecordsActualBytesAndKeepsRetryableEvidence() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        for text in ["one", "two"] { try Data(text.utf8).write(to: f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")) }
        let plan = try await store.previewStorageCleanup(); XCTAssertEqual(stages(plan).count, 2)
        files.failSecondTrash = true
        let result = try await store.cleanStorage(plan)
        XCTAssertEqual(result.movedCount, 1); XCTAssertEqual(result.movedBytes, 3); XCTAssertEqual(result.failedCount, 1)
        let receipt = try JSONDecoder().decode(CleanupReceipt.self, from: Data(contentsOf: result.receiptURL))
        XCTAssertEqual(receipt.outcomes.count, 2); XCTAssertEqual(receipt.outcomes.filter(\.verified).count, 1)
        let retry = try await f.makeStore(files: files).previewStorageCleanup(); XCTAssertEqual(stages(retry).count, 1); XCTAssertEqual(retry.byteCount, 3)
    }

    func testActiveImportBlocksCleanupInventoryUntilOperationEnds() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        files.blockCopy = true; files.failJournal = true
        let task = Task { try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 4) }
        let started = await Task.detached { files.waitForCopy() }.value
        XCTAssertTrue(started)
        do { _ = try await store.previewStorageCleanup(); XCTFail("Active import must block inventory") } catch { XCTAssertEqual(error as? StoreError, .operationInProgress) }
        files.copyResume.signal(); _ = try? await task.value
        let plan = try await store.previewStorageCleanup(); XCTAssertEqual(stages(plan).count, 1)
    }

    func testMissingFallbackPayloadProtectsMatchingStaging() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        let materialID = UUID(), versionID = UUID()
        let version = MaterialVersion(id: versionID, relativePath: "Materials/" + materialID.uuidString + "/" + versionID.uuidString + ".txt", sha256: digest(f.bytes), byteCount: Int64(f.bytes.count), kind: .original)
        var previous = WorkspaceSnapshot()
        previous.materials = [MaterialRecord(id: materialID, kind: .text, matterID: MatterGroup.ungroupedID, title: "missing recovery target", source: SourceRecord(origin: .note), versions: [version], originalVersionID: versionID, activeVersionID: versionID)]
        try JSONEncoder().encode(previous).write(to: f.root.appendingPathComponent("state.previous.json"))
        try files.copy(f.source, to: f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage"))
        let plan = try await store.previewStorageCleanup()
        XCTAssertEqual(plan.stagingInventory.first?.disposition, .referenced); XCTAssertTrue(stages(plan).isEmpty)
    }

    func testExportAndSelectedCleanupKeepOtherStagingAndSources() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        for text in ["one", "second"] { try Data(text.utf8).write(to: f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")) }
        let plan = try await store.previewStorageCleanup(), target = try XCTUnwrap(stages(plan).first)
        let output = f.source.deletingLastPathComponent().appendingPathComponent("retained.txt")
        _ = try await store.exportStagingCopy(target, from: plan, to: output)
        let data = try Data(contentsOf: f.root.appendingPathComponent(target.relativePath))
        XCTAssertEqual(try Data(contentsOf: output), data)
        do { _ = try await store.exportStagingCopy(target, from: plan, to: output); XCTFail("Export must not overwrite") } catch { XCTAssertEqual(error as? StoreError, .invalidPath) }
        do { _ = try await store.exportStagingCopy(target, from: plan, to: f.root.appendingPathComponent("Exports/retained.txt")); XCTFail("Retained copy must stay outside cleanup scope") } catch { XCTAssertEqual(error as? StoreError, .invalidPath) }
        let linkFolder = f.source.deletingLastPathComponent().appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: linkFolder, withDestinationURL: f.root)
        do { _ = try await store.exportStagingCopy(target, from: plan, to: linkFolder.appendingPathComponent("retained.txt")); XCTFail("Symlink destination must be refused") } catch { XCTAssertEqual(error as? StoreError, .invalidPath) }
        do { _ = try await store.exportStagingCopy(target, from: plan, to: f.source); XCTFail("Original must be preserved") } catch { XCTAssertEqual(error as? StoreError, .invalidPath) }
        let selected = plan.selecting([target.relativePath]), result = try await store.cleanStorage(selected)
        XCTAssertEqual(result.movedCount, 1); XCTAssertEqual(result.movedBytes, target.byteCount)
        XCTAssertEqual(try Data(contentsOf: output), data); XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        let remaining = try await store.previewStorageCleanup(); XCTAssertEqual(stages(remaining).count, 1)
    }

    func testUnknownDirectoryAndSymlinkRequireInspectionWithoutReadingSources() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        let directory = f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")
        try files.createDirectory(directory)
        let link = f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        let plan = try await store.previewStorageCleanup()
        XCTAssertEqual(plan.stagingInventory.filter { $0.disposition == .needsInspection }.count, 2)
        XCTAssertTrue(stages(plan).isEmpty); XCTAssertTrue(files.trashCalls.isEmpty); XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testJournalAddedAfterPreviewProtectsStagingAtRevalidation() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        _ = try await store.load()
        let stage = f.root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")
        try files.copy(f.source, to: stage)
        let plan = try await store.previewStorageCleanup(); XCTAssertEqual(stages(plan).count, 1)
        let materialID = UUID(), versionID = UUID(), transactionID = UUID()
        let version = MaterialVersion(id: versionID, relativePath: "Materials/" + materialID.uuidString + "/" + versionID.uuidString + ".txt", sha256: digest(f.bytes), byteCount: Int64(f.bytes.count), kind: .original)
        let record = MaterialRecord(id: materialID, kind: .text, matterID: MatterGroup.ungroupedID, title: "recovery", source: SourceRecord(origin: .note), versions: [version], originalVersionID: versionID, activeVersionID: versionID)
        let journal = StoreJournal(id: transactionID, phase: .contentReady, record: record)
        try JSONEncoder().encode(journal).write(to: f.root.appendingPathComponent("Transactions/" + transactionID.uuidString + ".json"))
        do { _ = try await store.cleanStorage(plan); XCTFail("New recovery references revoke cleanup eligibility") } catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
        XCTAssertEqual(try Data(contentsOf: stage), f.bytes); XCTAssertTrue(files.trashCalls.isEmpty)
    }

    func testFailedNotePublicationKeepsMatchingStageAsRecoveryEvidence() async throws {
        let f = try StoreFixture(), files = StagingTestFiles(), store = f.makeStore(files: files)
        let draft = try await store.createNoteDraft()
        _ = try await store.updateNoteDraft(draft.id, text: "recoverable note")
        files.failJournal = true
        do { _ = try await store.publishNoteDraft(draft.id); XCTFail("Note journal failure must surface") } catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        files.failJournal = false
        let reopened = f.makeStore(files: files), plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(plan.stagingInventory.first?.disposition, .referenced); XCTAssertTrue(stages(plan).isEmpty)
        let drafts = try await reopened.pendingNoteDrafts(); XCTAssertEqual(drafts.first?.text, "recoverable note")
        XCTAssertTrue(files.trashCalls.isEmpty)
    }

    private func stages(_ plan: StorageCleanupPlan) -> [CleanupTarget] { plan.targets.filter { $0.kind.rawValue == "unownedStaging" } }
}

final class StagingTestFiles: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    var failJournal = false, failBeforeStage = false, failAfterStage = false, failCommit = false, failSecondTrash = false, blockCopy = false
    let copyStarted = DispatchSemaphore(value: 0), copyResume = DispatchSemaphore(value: 0)
    var trashCalls: [(URL, URL)] = []
    func waitForCopy() -> Bool { copyStarted.wait(timeout: .now() + 5) == .success }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func copy(_ source: URL, to destination: URL) throws {
        if failBeforeStage { throw StoreError.unavailableSpace }
        try base.copy(source, to: destination)
        if blockCopy { copyStarted.signal(); _ = copyResume.wait(timeout: .now() + 10) }
        if failAfterStage { throw StoreError.unavailableSpace }
    }
    func move(_ source: URL, to destination: URL) throws { if failCommit { throw StoreError.unavailableSpace }; try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws {
        if failJournal && destination.deletingLastPathComponent().lastPathComponent == "Transactions" && destination.pathExtension == "json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: destination)
    }
    func trash(_ source: URL) throws -> URL {
        if failSecondTrash && trashCalls.count == 1 { throw StoreError.unavailableSpace }
        let folder = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("simulated-trash")
        try base.createDirectory(folder)
        let destination = folder.appendingPathComponent(UUID().uuidString)
        try base.move(source, to: destination); trashCalls.append((source, destination)); return destination
    }
}
