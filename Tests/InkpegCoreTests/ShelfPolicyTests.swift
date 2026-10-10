import XCTest
@testable import InkpegCore

func fixture(_ order: Int = 0, pinned: Bool = false, matter: UUID = MatterGroup.ungroupedID) -> MaterialRecord {
    let version = MaterialVersion(relativePath: "Materials/test/original", sha256: "hash", byteCount: 1, kind: .original)
    return MaterialRecord(kind: .text, matterID: matter, pinned: pinned, order: order, title: "摘录", source: SourceRecord(origin: .clipboard), versions: [version], originalVersionID: version.id, activeVersionID: version.id)
}
final class ShelfPolicyTests: XCTestCase {
    func testCapacityThreeTakesDownOldestUnpinned() {
        var state = WorkspaceSnapshot()
        state.materials = [fixture(0, pinned: true), fixture(1, pinned: true), fixture(2)]
        let incoming = fixture(3)
        let result = ShelfPolicy.admit(incoming, snapshot: state, capacity: 3)
        XCTAssertEqual(result.disposition, .hanging(incoming.id))
        XCTAssertEqual(result.snapshot.materials.count, 4)
        XCTAssertEqual(result.snapshot.materials[2].status, .takenDown)
        XCTAssertTrue(result.snapshot.materials.filter { $0.pinned }.allSatisfy { $0.status == .hanging })
    }
    func testAllPinnedRejectsIncoming() {
        var state = WorkspaceSnapshot()
        state.materials = [fixture(0, pinned: true), fixture(1, pinned: true), fixture(2, pinned: true)]
        XCTAssertFalse(ShelfPolicy.canAdmit(snapshot: state, matterID: state.selectedMatterID, capacity: 3))
        let result = ShelfPolicy.admit(fixture(3), snapshot: state, capacity: 3)
        XCTAssertEqual(result.disposition, .shelfFull)
        XCTAssertEqual(result.snapshot, state)
    }
    func testCrossMatterAdmissionDoesNotEvictOtherMatter() {
        var state = WorkspaceSnapshot()
        let other = UUID()
        state.matters.append(MatterGroup(id: other, name: "其他事项"))
        state.materials = [fixture(0, matter: other), fixture(1, matter: other), fixture(2, matter: other)]
        let result = ShelfPolicy.admit(fixture(3), snapshot: state, capacity: 3)
        XCTAssertEqual(Array(result.snapshot.materials.prefix(3)), state.materials)
        XCTAssertEqual(result.snapshot.materials.count, 4)
    }
    func testNarrowScreenDoesNotMutateSnapshot() {
        var state = WorkspaceSnapshot()
        state.materials = (0..<8).map { fixture($0) }
        let original = state
        XCTAssertEqual(ShelfPolicy.visible(snapshot: state, matterID: state.selectedMatterID, capacity: 3).count, 3)
        XCTAssertEqual(state, original)
    }
}
final class CoreModelTests: XCTestCase {
    func testSnapshotRoundTripKeepsIDsAndSource() throws {
        var state = WorkspaceSnapshot()
        var record = fixture()
        record.source = SourceRecord(origin: .fileSelection, filePath: "/synthetic/seven.pdf", fileBookmark: Data([1,2]), webURL: URL(string: "https://example.invalid/item"), locator: .pdfIndex(6), isManuallyRegistered: true)
        state.materials = [record]
        state.privacyHidden = true
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.materials[0].id, record.id)
        XCTAssertEqual(decoded.materials[0].originalVersionID, record.originalVersionID)
    }
}
