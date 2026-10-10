import XCTest
@testable import InkpegCore

final class EditingRecoveryRebaseTests: XCTestCase {
    func testExplicitRecoveryRebasesKnownOlderDraftWithoutChangingMaterial() async throws {
        let f = try StoreFixture(), normal = f.makeStore()
        let initial = try await normal.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(initial.snapshot.materials.first?.id)
        let session = try await normal.createDerivedVersion(of: id, kind: .textEdit)
        let failing = f.makeStore(files: FaultFiles(.snapshotWrite))
        try await failing.writeEditingResult(session, data: Data("第一次失败的副本".utf8))
        do { _ = try await failing.finishEditing(session, result: .save(session.workingURL)); XCTFail("Must reach injected failure") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let latest = Data("失败后继续写入的最新草稿".utf8)
        try await failing.writeEditingResult(session, data: latest)
        let restarted = f.makeStore(), before = try await restarted.load()
        let resumed = try await restarted.resumeEditingSession(session)
        XCTAssertEqual(resumed.id, session.id)
        XCTAssertEqual(resumed.workingURL, session.workingURL)
        XCTAssertEqual(resumed.baseVersionID, before.materials.first?.activeVersionID)
        let after = try await restarted.load()
        XCTAssertEqual(after.materials, before.materials, "Resume does not edit material content or versions")
        XCTAssertEqual(after.matters, before.matters)
        XCTAssertEqual(after.privacyHidden, before.privacyHidden)
        XCTAssertEqual(after.generation, before.generation + 1, "Recovered base must be durable before replacing its journal chain")
        let disk = try await f.makeStore().load()
        XCTAssertEqual(disk.materials, after.materials)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), latest)
        let saved = try await restarted.finishEditing(resumed, result: .save(resumed.workingURL))
        let payload = try await restarted.payloadURL(of: id)
        XCTAssertEqual(try Data(contentsOf: payload), latest)
        XCTAssertEqual(saved.materials.first?.originalVersionID, initial.snapshot.materials.first?.originalVersionID)
        XCTAssertEqual(saved.materials.first?.source, initial.snapshot.materials.first?.source)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testRecoveryAnchorWriteFailureLeavesOriginalSessionAndLatestDraft() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let session = try await store.createDerivedVersion(of: id, kind: .textEdit)
        let failing = f.makeStore(files: FaultFiles(.snapshotWrite))
        try await failing.writeEditingResult(session, data: Data("第一次写盘失败".utf8))
        do { _ = try await failing.finishEditing(session, result: .save(session.workingURL)); XCTFail("Injected snapshot write must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let latest = Data("仍待恢复的最新正文".utf8)
        try await failing.writeEditingResult(session, data: latest)
        let metadata = session.workingURL.deletingLastPathComponent().appendingPathComponent("session.json")
        let before = try Data(contentsOf: metadata)
        let restarted = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await restarted.resumeEditingSession(session); XCTFail("Recovery anchor must be durable") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertEqual(try Data(contentsOf: session.workingURL), latest)
    }
    func testRecoveryRejectsUnknownAncestorAndForgedWorkingURL() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let session = try await store.createDerivedVersion(of: id, kind: .textEdit)
        let metadata = session.workingURL.deletingLastPathComponent().appendingPathComponent("session.json")
        for forged in [EditSession(id: session.id, materialID: id, baseVersionID: UUID(), workingURL: session.workingURL, kind: .textEdit), EditSession(id: session.id, materialID: id, baseVersionID: session.baseVersionID, workingURL: f.source, kind: .textEdit)] {
            try JSONEncoder().encode(forged).write(to: metadata)
            do { _ = try await store.resumeEditingSession(forged); XCTFail("Forged recovery must be refused") }
            catch { XCTAssertEqual(error as? StoreError, .invalidEdit) }
        }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
}
