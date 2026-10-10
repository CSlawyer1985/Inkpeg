import XCTest
@testable import InkpegCore

final class StorageBudgetTests: XCTestCase {
    func testDiskFullLeavesSnapshotAndSourceIntact() async throws {
        let f = try StoreFixture()
        do { _ = try await f.makeStore(files: FaultFiles(.noSpace)).importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("No-space import accepted") } catch { XCTAssertEqual(error as? StoreError, .budgetExceeded) }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testBudgetBoundary() async throws {
        let f = try StoreFixture()
        let n = Int64(f.bytes.count)
        let store = MaterialStore(root: f.root, files: FaultFiles(), budget: StorageBudget(maxFileBytes: n, maxMaterialBytes: n, minimumFreeBytes: 0))
        let result = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertEqual(result.snapshot.materials.count, 1)
        let extra = f.source.deletingLastPathComponent().appendingPathComponent("extra.txt")
        try f.bytes.write(to: extra)
        do { _ = try await store.importMaterial(.file(extra, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("Storage budget exceeded") } catch { XCTAssertEqual(error as? StoreError, .budgetExceeded) }
    }
}
