import Foundation
import XCTest
@testable import InkpegCore

final class FinalCoreRebaseBoundaryAuditTests: XCTestCase {
    func testExplicitRebaseKeepsRecoveryChainAcrossSecondFailedSaveAndRestart() async throws {
        let f = try StoreFixture(), normal = f.makeStore()
        let imported = try await normal.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await normal.createDerivedVersion(of: record.id, kind: .textEdit)
        let failed = f.makeStore(files: FaultFiles(.snapshotWrite))
        let earlier = Data("first interrupted version".utf8), latest = Data("latest recovered working copy".utf8)
        try await failed.writeEditingResult(session, data: earlier)
        do { _ = try await failed.finishEditing(session, result: .save(session.workingURL)); XCTFail("Initial injected snapshot failure must report") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        try await failed.writeEditingResult(session, data: latest)

        let firstRestart = f.makeStore()
        let firstRecovered = try await firstRestart.load()
        let firstVersion = try XCTUnwrap(firstRecovered.materials.first?.activeVersion)
        let resumed = try await firstRestart.resumeEditingSession(session)
        XCTAssertEqual(resumed.id, session.id)
        XCTAssertEqual(resumed.baseVersionID, firstVersion.id)
        let anchored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: f.root.appendingPathComponent("state.json")))
        XCTAssertEqual(anchored.materials.first?.activeVersionID, resumed.baseVersionID)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), latest)

        let secondFailed = f.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await secondFailed.finishEditing(resumed, result: .save(resumed.workingURL)); XCTFail("Second injected snapshot failure must report") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let secondRestart = f.makeStore()
        let secondRecovered = try await secondRestart.load()
        let active = try await secondRestart.payloadURL(of: record.id)
        XCTAssertEqual(try Data(contentsOf: active), latest)
        XCTAssertEqual(secondRecovered.materials.first?.versions.count, 3)
        XCTAssertEqual(secondRecovered.materials.first?.originalVersionID, record.originalVersionID)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(firstVersion.relativePath)), earlier)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testFailedRecoveryAnchorLeavesOriginalMetadataAndLatestWorkingRecoverable() async throws {
        let f = try StoreFixture(), normal = f.makeStore()
        let imported = try await normal.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await normal.createDerivedVersion(of: record.id, kind: .textEdit)
        let failed = f.makeStore(files: FaultFiles(.snapshotWrite))
        try await failed.writeEditingResult(session, data: Data("interrupted active version".utf8))
        do { _ = try await failed.finishEditing(session, result: .save(session.workingURL)); XCTFail("Initial injected snapshot failure must report") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let latest = Data("latest draft before anchor failure".utf8)
        try await failed.writeEditingResult(session, data: latest)
        let metadata = session.workingURL.deletingLastPathComponent().appendingPathComponent("session.json")
        let metadataBefore = try Data(contentsOf: metadata)
        let restartWithFault = f.makeStore(files: FaultFiles(.snapshotWrite))
        _ = try await restartWithFault.load()
        do { _ = try await restartWithFault.resumeEditingSession(session); XCTFail("Explicit recovery must report anchor write failure") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertEqual(try Data(contentsOf: metadata), metadataBefore)
        XCTAssertEqual(try JSONDecoder().decode(EditSession.self, from: Data(contentsOf: metadata)), session)
        XCTAssertEqual(try Data(contentsOf: session.workingURL), latest)
        let finalRestart = f.makeStore()
        let pending = try await finalRestart.pendingEditSessions()
        XCTAssertTrue(pending.contains { $0.id == session.id })
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
}
