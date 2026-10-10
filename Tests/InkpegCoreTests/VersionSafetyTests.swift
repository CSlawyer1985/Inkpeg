import XCTest
@testable import InkpegCore
final class VersionSafetyTests: XCTestCase {
    func testDerivedSaveAndCancelPreserveOriginalAndSource() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let before = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let record = try XCTUnwrap(before.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        XCTAssertNotEqual(session.workingURL, f.source)
        let managed = try await store.payloadURL(of: record.id)
        XCTAssertNotEqual(session.workingURL, managed)
        try Data("修改后的合成文字".utf8).write(to: session.workingURL)
        let after = try await store.finishEditing(session, result: .save(session.workingURL))
        let edited = try XCTUnwrap(after.materials.first)
        XCTAssertEqual(edited.originalVersionID, record.originalVersionID)
        XCTAssertNotEqual(edited.activeVersionID, record.activeVersionID)
        XCTAssertEqual(edited.versions.count, 2)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(record.versions[0].relativePath)), f.bytes)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        let cancelled = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try Data("取消的文字".utf8).write(to: cancelled.workingURL)
        let cancelledState = try await store.finishEditing(cancelled, result: .cancel)
        XCTAssertEqual(cancelledState, after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelled.workingURL.path))
    }
    func testSessionSurvivesRestartButStaleBaseCannotReplaceNewVersion() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let first = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        let stale = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try Data("first".utf8).write(to: first.workingURL)
        let restarted = f.makeStore()
        _ = try await restarted.finishEditing(first, result: .save(first.workingURL))
        do { _ = try await restarted.finishEditing(stale, result: .save(stale.workingURL)); XCTFail("Must reject stale session") }
        catch { XCTAssertEqual(error as? StoreError, .invalidEdit) }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testExternalSaveURLRejectedAndSnapshotFailureRetainsDraft() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        do { _ = try await store.finishEditing(session, result: .save(f.source)); XCTFail("External URL prohibited") }
        catch { XCTAssertEqual(error as? StoreError, .invalidEdit) }
        let fault = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await fault.finishEditing(session, result: .save(session.workingURL)); XCTFail("Cannot report save") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.workingURL.path))
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
}

extension VersionSafetyTests {
    func testDerivedCommitFailureRecoversVersionAsNeedsReview() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try Data("pending version".utf8).write(to: session.workingURL)
        let fault = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await fault.finishEditing(session, result: .save(session.workingURL)); XCTFail("Failed snapshot cannot report success") } catch {}
        let recovered = try await f.makeStore().load()
        XCTAssertEqual(recovered.materials.first?.status, .needsReview)
        XCTAssertEqual(recovered.materials.first?.versions.count, 2)
        XCTAssertEqual(recovered.materials.first?.originalVersionID, record.originalVersionID)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testMarkupDetectsActualFormatAndPreservesOriginal() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let source = f.source.deletingLastPathComponent().appendingPathComponent("original.jpg")
        try png.write(to: source)
        let imported = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .markup)
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        try gif.write(to: session.workingURL)
        let edited = try await store.finishEditing(session, result: .save(session.workingURL))
        XCTAssertTrue(edited.materials.first?.activeVersion?.relativePath.hasSuffix(".gif") == true)
        XCTAssertEqual(edited.materials.first?.activeVersion?.kind, .markup)
        XCTAssertEqual(try Data(contentsOf: source), png)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(record.versions[0].relativePath)), png)
    }
}
extension VersionSafetyTests {
    func testCancelledDraftIsDiscoverableAfterRestart() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try Data("unsaved draft".utf8).write(to: session.workingURL)
        _ = try await store.finishEditing(session, result: .cancel)
        let drafts = try await f.makeStore().pendingEditSessions()
        XCTAssertEqual(drafts, [session])
    }
    func testRecoveredPendingVersionCanBeExplicitlyHung() async throws {
        let f = try StoreFixture(), store = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3) } catch {}
        let restarted = f.makeStore(), recovered = try await restarted.load()
        let record = try XCTUnwrap(recovered.materials.first)
        XCTAssertEqual(record.status, .needsReview)
        let accepted = try await restarted.apply(.hang(record.id))
        XCTAssertEqual(accepted.materials.first?.status, .hanging)
        XCTAssertEqual(accepted.materials.first?.versions, record.versions)
    }
}
