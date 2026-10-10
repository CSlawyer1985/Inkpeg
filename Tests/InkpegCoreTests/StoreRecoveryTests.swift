import XCTest
@testable import InkpegCore

final class StoreRecoveryTests: XCTestCase {
    func testRestartRestoresStableIDsAndOwnedVersion() async throws {
        let f = try StoreFixture()
        let initial = try await f.makeStore().importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertFalse(initial.snapshot.materials.isEmpty)
        let restored = try await f.makeStore().load()
        XCTAssertEqual(restored, initial.snapshot)
    }
    func testCorruptCurrentStateKeepsPreviousAndEvidence() async throws {
        let f = try StoreFixture()
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let previous = try JSONEncoder().encode(WorkspaceSnapshot())
        let corrupted = Data("corrupted state".utf8)
        try previous.write(to: f.root.appendingPathComponent("state.previous.json"))
        try corrupted.write(to: f.root.appendingPathComponent("state.json"))
        do { _ = try await f.makeStore().load(); XCTFail("Corrupt state silently accepted") } catch { XCTAssertEqual(error as? StoreError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.json")), corrupted)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.previous.json")), previous)
    }
    func testUnknownSchemaIsNeverOverwritten() async throws {
        let f = try StoreFixture()
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        var future = WorkspaceSnapshot(); future.schemaVersion = 99
        let bytes = try JSONEncoder().encode(future)
        try bytes.write(to: f.root.appendingPathComponent("state.json"))
        do { _ = try await f.makeStore().load(); XCTFail("Unknown schema accepted") } catch { XCTAssertEqual(error as? StoreError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.json")), bytes)
    }
    func testSnapshotRelativeTraversalIsRejected() async throws {
        let f = try StoreFixture()
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let v = MaterialVersion(relativePath: "../source.txt", sha256: digest(f.bytes), byteCount: Int64(f.bytes.count), kind: .original)
        var state = WorkspaceSnapshot()
        state.materials = [MaterialRecord(kind: .text, title: "synthetic", source: SourceRecord(origin: .fileSelection), versions: [v], originalVersionID: v.id, activeVersionID: v.id)]
        try JSONEncoder().encode(state).write(to: f.root.appendingPathComponent("state.json"))
        do { _ = try await f.makeStore().load(); XCTFail("Traversal accepted") } catch {}
    }
    func testCrashAfterContentCommitRecoversPendingTransaction() async throws {
        let f = try StoreFixture()
        do { _ = try await f.makeStore(files: FaultFiles(.snapshotWrite)).importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("State failure not propagated") } catch {}
        let recovered = try await f.makeStore().load()
        XCTAssertEqual(recovered.materials.count, 1)
        XCTAssertEqual(recovered.materials.first?.status, .needsReview)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testExplicitPreviousRecoveryPreservesDamagedState() async throws {
        let f = try StoreFixture()
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let previous = try JSONEncoder().encode(WorkspaceSnapshot())
        let damaged = Data("damaged synthetic state".utf8)
        try previous.write(to: f.root.appendingPathComponent("state.previous.json"))
        try damaged.write(to: f.root.appendingPathComponent("state.json"))
        let restored = try await f.makeStore().restorePreviousSnapshot()
        XCTAssertTrue(restored.materials.isEmpty)
        let evidence = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("state.damaged.") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(evidence.first)), damaged)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.previous.json")), previous)
        let reloaded = try await f.makeStore().load()
        XCTAssertEqual(reloaded, restored)
    }

}
