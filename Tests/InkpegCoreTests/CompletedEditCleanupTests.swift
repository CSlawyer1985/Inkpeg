import XCTest
@testable import InkpegCore

final class CompletedEditCleanupTests: XCTestCase {
    func testSavedEditIsEligibleAndExplicitCleanupMovesMaterialAndSessionWithReceipt() async throws {
        try await verifySavedCleanup(restart: false)
    }

    func testSavedEditRemainsEligibleAfterRestart() async throws {
        try await verifySavedCleanup(restart: true)
    }

    private func verifySavedCleanup(restart: Bool) async throws {
        let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
        let original = try await importRecord(f, store)
        let session = try await store.createDerivedVersion(of: original.id, kind: .textEdit)
        let edited = Data("saved edit".utf8)
        try await store.writeEditingResult(session, data: edited)
        let saved = try await store.finishEditing(session, result: .save(session.workingURL))
        _ = try await store.apply(.takeDown(original.id))
        let active = restart ? f.makeStore(files: files) : store
        let snapshotBytes = try Data(contentsOf: f.root.appendingPathComponent("state.json"))
        let pending = try await active.pendingEditSessions(), plan = try await active.previewStorageCleanup()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(plan.materialCount, 1); XCTAssertEqual(plan.completedEditCount, 1)
        XCTAssertTrue(plan.targets.contains { $0.relativePath == "Drafts/" + session.id.uuidString })
        XCTAssertEqual(plan.targets.count, 2)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.json")), snapshotBytes)
        XCTAssertEqual(try Data(contentsOf: session.workingURL), edited)
        XCTAssertTrue(files.trashCalls.isEmpty, "Save and preview must retain the draft until explicit cleanup")
        let result = try await active.cleanStorage(plan)
        XCTAssertEqual(result.movedCount, 2); XCTAssertEqual(result.failedCount, 0); XCTAssertEqual(result.unverifiedCount, 0)
        let receipt = try JSONDecoder().decode(CleanupReceipt.self, from: Data(contentsOf: result.receiptURL))
        XCTAssertEqual(receipt.targets, plan.targets); XCTAssertEqual(receipt.outcomes.count, 2)
        XCTAssertTrue(receipt.outcomes.allSatisfy { $0.verified && $0.trashURL != nil })
        let materialTrash = try XCTUnwrap(files.trashCalls.first { $0.0.lastPathComponent == original.id.uuidString }?.1)
        let draftTrash = try XCTUnwrap(files.trashCalls.first { $0.0.lastPathComponent == session.id.uuidString }?.1)
        XCTAssertEqual(digest(try Data(contentsOf: materialTrash.appendingPathComponent(URL(fileURLWithPath: original.versions[0].relativePath).lastPathComponent))), original.versions[0].sha256)
        XCTAssertEqual(try Data(contentsOf: draftTrash.appendingPathComponent(session.workingURL.lastPathComponent)), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.workingURL.path))
        XCTAssertEqual(digest(try Data(contentsOf: f.source)), digest(f.bytes))
        let reopened = f.makeStore(files: files), final = try await reopened.load()
        XCTAssertEqual(final.materials.first?.status, .trashed)
        XCTAssertEqual(final.materials.first?.activeVersionID, saved.materials.first?.activeVersionID)
        let remaining = try await reopened.previewStorageCleanup()
        XCTAssertTrue(remaining.targets.isEmpty)
    }

    func testCompletedDraftCanBeCleanedWhileMaterialIsHanging() async throws {
        let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
        let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        let saved = try await store.finishEditing(session, result: .save(session.workingURL))
        let plan = try await store.previewStorageCleanup()
        XCTAssertEqual(plan.materialCount, 0); XCTAssertEqual(plan.targets.count, 1)
        let result = try await store.cleanStorage(plan)
        XCTAssertEqual(result.movedCount, 1); XCTAssertEqual(result.snapshot, saved)
        let payload = try await store.payloadURL(of: record.id)
        XCTAssertEqual(try Data(contentsOf: payload), f.bytes)
    }

    func testUnmodifiedNewActiveSessionRemainsPendingEvenAfterEarlierSave() async throws {
        let f = try StoreFixture(), store = f.makeStore(), record = try await importRecord(f, store)
        let completed = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        _ = try await store.finishEditing(completed, result: .save(completed.workingURL))
        let active = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        _ = try await store.apply(.takeDown(record.id))
        let pending = try await f.makeStore().pendingEditSessions(), plan = try await f.makeStore().previewStorageCleanup()
        XCTAssertEqual(pending, [active]); XCTAssertEqual(plan.materialCount, 0)
        XCTAssertFalse(plan.targets.contains { $0.relativePath == "Drafts/" + active.id.uuidString })
    }

    func testCancelledDifferentContentRemainsProtectedAndRecoverable() async throws {
        let f = try StoreFixture(), store = f.makeStore(), record = try await importRecord(f, store)
        let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit), draft = Data("cancelled draft".utf8)
        try await store.writeEditingResult(session, data: draft)
        _ = try await store.finishEditing(session, result: .cancel)
        _ = try await store.apply(.takeDown(record.id))
        let reopened = f.makeStore(), pending = try await reopened.pendingEditSessions(), plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(pending, [session]); XCTAssertTrue(plan.targets.isEmpty)
        let resumed = try await reopened.resumeEditingSession(session)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), draft)
        XCTAssertEqual(digest(try Data(contentsOf: f.source)), digest(f.bytes))
    }

    func testOlderActiveSessionMatchingAnotherSessionsSaveIsNotCompleted() async throws {
        let f = try StoreFixture(), store = f.makeStore(), record = try await importRecord(f, store)
        let first = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        let other = try await store.createDerivedVersion(of: record.id, kind: .textEdit), bytes = Data("same edited content".utf8)
        try await store.writeEditingResult(first, data: bytes); try await store.writeEditingResult(other, data: bytes)
        _ = try await store.finishEditing(first, result: .save(first.workingURL))
        _ = try await store.apply(.takeDown(record.id))
        let reopened = f.makeStore(), pending = try await reopened.pendingEditSessions(), plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(pending, [other], "Matching bytes alone cannot complete a different active session")
        XCTAssertEqual(plan.materialCount, 0)
        XCTAssertFalse(plan.targets.contains { $0.relativePath == "Drafts/" + other.id.uuidString })
    }

    func testOlderBaselineWithDifferentWorkingContentCanExplicitlyResume() async throws {
        let f = try StoreFixture(), store = f.makeStore(), record = try await importRecord(f, store)
        let first = try await store.createDerivedVersion(of: record.id, kind: .textEdit), older = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try await store.writeEditingResult(first, data: Data("committed".utf8))
        let saved = try await store.finishEditing(first, result: .save(first.workingURL))
        _ = try await store.apply(.takeDown(record.id))
        let reopened = f.makeStore(), plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(plan.materialCount, 0)
        let resumed = try await reopened.resumeEditingSession(older)
        XCTAssertEqual(resumed.baseVersionID, saved.materials.first?.activeVersionID)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), f.bytes)
        XCTAssertEqual(digest(try Data(contentsOf: f.source)), digest(f.bytes))
    }

    func testSaveFailuresAtJournalAndSnapshotBoundariesKeepRecoveryProtected() async throws {
        for fault in [CompletedEditTestFiles.Fault.firstJournal, .secondJournal, .previousSnapshot, .snapshot] {
            let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
            let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
            let draft = Data("recoverable failure".utf8)
            try await store.writeEditingResult(session, data: draft)
            files.fault = fault
            do { _ = try await store.finishEditing(session, result: .save(session.workingURL)); XCTFail("Injected failure must surface: \(fault)") }
            catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
            let reopened = f.makeStore(files: files), recovered = try await reopened.load()
            if fault != .firstJournal { XCTAssertEqual(recovered.materials.first?.status, .needsReview) }
            let pending = try await reopened.pendingEditSessions()
            XCTAssertEqual(pending, [session], "Failed saves stay recoverable: \(fault)")
            if fault == .firstJournal { _ = try await reopened.apply(.takeDown(record.id)) }
            let plan = try await reopened.previewStorageCleanup()
            XCTAssertTrue(plan.targets.isEmpty, "Unreviewed failed content and session must remain protected: \(fault)")
            XCTAssertEqual(try Data(contentsOf: session.workingURL), draft)
            XCTAssertEqual(digest(try Data(contentsOf: f.source)), record.versions[0].sha256)
            XCTAssertTrue(files.trashCalls.isEmpty)
        }
    }

    func testRecoveredPendingSaveCanBeCleanedAfterExplicitTakeDownAndRestart() async throws {
        for fault in [CompletedEditTestFiles.Fault.secondJournal, .snapshot] {
            let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
            let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
            let bytes = Data("explicitly reviewed recovery".utf8)
            try await store.writeEditingResult(session, data: bytes)
            files.fault = fault
            do { _ = try await store.finishEditing(session, result: .save(session.workingURL)); XCTFail("Injected failure must surface") }
            catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
            let recovered = f.makeStore(files: files), snapshot = try await recovered.load()
            XCTAssertEqual(snapshot.materials.first?.status, .needsReview)
            let protected = try await recovered.previewStorageCleanup()
            XCTAssertTrue(protected.targets.isEmpty)
            _ = try await recovered.apply(.takeDown(record.id))
            let restarted = f.makeStore(files: files), plan = try await restarted.previewStorageCleanup()
            XCTAssertEqual(plan.materialCount, 1); XCTAssertEqual(plan.completedEditCount, 1)
            let version = try XCTUnwrap(snapshot.materials.first?.activeVersion)
            XCTAssertEqual(version.sha256, digest(bytes))
            let result = try await restarted.cleanStorage(plan)
            XCTAssertEqual(result.movedCount, 2)
            let receipt = try JSONDecoder().decode(CleanupReceipt.self, from: Data(contentsOf: result.receiptURL))
            XCTAssertEqual(receipt.outcomes.count, 2); XCTAssertTrue(receipt.outcomes.allSatisfy(\.verified))
            let materialTrash = try XCTUnwrap(files.trashCalls.first { $0.0.lastPathComponent == record.id.uuidString }?.1)
            XCTAssertEqual(digest(try Data(contentsOf: materialTrash.appendingPathComponent(URL(fileURLWithPath: version.relativePath).lastPathComponent))), version.sha256)
            XCTAssertEqual(digest(try Data(contentsOf: f.source)), record.versions[0].sha256)
        }
    }

    func testCrashAfterDurableSnapshotRecognizesCompletedEditOnRestart() async throws {
        let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
        let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try await store.writeEditingResult(session, data: Data("durable before crash".utf8))
        files.fault = .afterSnapshot
        do { _ = try await store.finishEditing(session, result: .save(session.workingURL)); XCTFail("Simulated crash must interrupt return") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let reopened = f.makeStore(files: files), recovered = try await reopened.load()
        XCTAssertEqual(recovered.materials.first?.status, .hanging)
        let pending = try await reopened.pendingEditSessions()
        XCTAssertTrue(pending.isEmpty)
        _ = try await reopened.apply(.takeDown(record.id))
        let plan = try await reopened.previewStorageCleanup()
        XCTAssertEqual(plan.materialCount, 1); XCTAssertEqual(plan.targets.count, 2)
        XCTAssertEqual(digest(try Data(contentsOf: f.source)), record.versions[0].sha256)
    }

    func testUnknownOrDamagedSessionsFailClosedWithoutTrash() async throws {
        for mode in 0..<3 {
            let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
            let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
            let metadata = session.workingURL.deletingLastPathComponent().appendingPathComponent("session.json")
            if mode == 0 { try Data("damaged".utf8).write(to: metadata) }
            if mode == 1 {
                let unknown = EditSession(id: session.id, materialID: record.id, baseVersionID: UUID(), workingURL: session.workingURL, kind: .textEdit)
                try JSONEncoder().encode(unknown).write(to: metadata)
            }
            if mode == 2 { try Data("unknown evidence".utf8).write(to: metadata.deletingLastPathComponent().appendingPathComponent("unknown.txt")) }
            _ = try await store.apply(.takeDown(record.id))
            do { _ = try await store.previewStorageCleanup(); XCTFail("Unknown evidence must block cleanup") } catch {}
            XCTAssertTrue(files.trashCalls.isEmpty)
            XCTAssertEqual(digest(try Data(contentsOf: f.source)), record.versions[0].sha256)
        }
    }

    func testChangedCompletedDraftInvalidatesCleanupApproval() async throws {
        let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
        let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        _ = try await store.finishEditing(session, result: .save(session.workingURL))
        _ = try await store.apply(.takeDown(record.id))
        let plan = try await store.previewStorageCleanup()
        try await store.writeEditingResult(session, data: Data("new unsaved draft".utf8))
        do { _ = try await store.cleanStorage(plan); XCTFail("Approval must not discard changed recovery content") }
        catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
        XCTAssertTrue(files.trashCalls.isEmpty)
        let pending = try await store.pendingEditSessions()
        XCTAssertEqual(pending, [session])
    }

    func testInterruptedReceiptAfterMaterialMoveCanRetryCompletedDraftAfterRestart() async throws {
        let f = try StoreFixture(), files = CompletedEditTestFiles(), store = f.makeStore(files: files)
        let record = try await importRecord(f, store), session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        _ = try await store.finishEditing(session, result: .save(session.workingURL))
        _ = try await store.apply(.takeDown(record.id))
        let plan = try await store.previewStorageCleanup()
        files.receiptWritesUntilFailure = 2
        do { _ = try await store.cleanStorage(plan); XCTFail("Receipt fault stops before moving the draft") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertEqual(files.trashCalls.count, 1)
        XCTAssertEqual(try Data(contentsOf: session.workingURL), f.bytes)
        let reopened = f.makeStore(files: files), snapshot = try await reopened.load()
        XCTAssertEqual(snapshot.materials.first?.status, .trashed)
        let retry = try await reopened.previewStorageCleanup()
        XCTAssertEqual(retry.materialCount, 0); XCTAssertEqual(retry.completedEditCount, 1)
        let result = try await reopened.cleanStorage(retry)
        XCTAssertEqual(result.movedCount, 1)
        let receipt = try JSONDecoder().decode(CleanupReceipt.self, from: Data(contentsOf: result.receiptURL))
        XCTAssertEqual(receipt.outcomes.count, 1); XCTAssertEqual(receipt.outcomes.first?.verified, true)
        let remaining = try await f.makeStore(files: files).previewStorageCleanup()
        XCTAssertTrue(remaining.targets.isEmpty)
        XCTAssertEqual(digest(try Data(contentsOf: f.source)), record.versions[0].sha256)
    }

    func testCompletedWorkingCopiesHaveAccurateLabelsAndCountsInAllLocales() throws {
        let labels = ["zh-Hans": "已完成编辑的工作副本", "en": "Completed edit working copies", "es": "Copias de trabajo de ediciones completadas"]
        for (locale, expected) in labels {
            let localizer = Localizer(localeIdentifier: locale)
            XCTAssertEqual(localizer.string(.cleanupCompletedEdits), expected)
            let summary = String(format: localizer.string(.cleanupSummary), 2, 3, 4, "123 B")
            XCTAssertTrue(summary.contains("2")); XCTAssertTrue(summary.contains("3"))
            XCTAssertTrue(summary.contains("4")); XCTAssertTrue(summary.contains("123 B"))
        }
    }

    private func importRecord(_ f: StoreFixture, _ store: MaterialStore) async throws -> MaterialRecord {
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        return try XCTUnwrap(imported.snapshot.materials.first)
    }
}

private final class CompletedEditTestFiles: FileOperations, @unchecked Sendable {
    enum Fault { case firstJournal, secondJournal, previousSnapshot, snapshot, afterSnapshot }
    let base = SystemFileOperations()
    var fault: Fault?
    var journalWrites = 0
    var receiptWritesUntilFailure: Int?
    var trashCalls: [(URL, URL)] = []
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func writeAtomic(_ data: Data, to destination: URL) throws {
        if destination.deletingLastPathComponent().lastPathComponent == "CleanupRecords", let remaining = receiptWritesUntilFailure {
            receiptWritesUntilFailure = remaining == 1 ? nil : remaining - 1
            if remaining == 1 { throw StoreError.unavailableSpace }
        }
        if let fault {
            if destination.deletingLastPathComponent().lastPathComponent == "Transactions" { journalWrites += 1 }
            let reject = (fault == .firstJournal && journalWrites == 1) || (fault == .secondJournal && journalWrites == 2) ||
                (fault == .previousSnapshot && destination.lastPathComponent == "state.previous.json") ||
                ((fault == .snapshot || fault == .afterSnapshot) && destination.lastPathComponent == "state.json")
            if reject {
                self.fault = nil
                if fault == .afterSnapshot { try base.writeAtomic(data, to: destination) }
                throw StoreError.unavailableSpace
            }
        }
        try base.writeAtomic(data, to: destination)
    }
    func trash(_ source: URL) throws -> URL {
        // Synthetic Trash preserves all fixtures; no test performs permanent deletion.
        let trash = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("simulated-trash")
        try base.createDirectory(trash)
        let destination = trash.appendingPathComponent(UUID().uuidString)
        try base.move(source, to: destination); trashCalls.append((source, destination))
        return destination
    }
}
