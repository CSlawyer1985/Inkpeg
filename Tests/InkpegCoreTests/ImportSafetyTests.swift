import XCTest
import CoreGraphics
@testable import InkpegCore

final class ImportSafetyTests: XCTestCase {
    func testImportPreservesOriginalBytesPathAndMtime() async throws {
        let f = try StoreFixture()
        let original = try SystemFileOperations().inspect(f.source)
        let result = try await f.makeStore().importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        guard case .hanging(let id) = result.disposition else { return XCTFail("Expected successful safe import") }
        let record = try XCTUnwrap(result.snapshot.materials.first { $0.id == id })
        let version = try XCTUnwrap(record.activeVersion)
        let copy = f.root.appendingPathComponent(version.relativePath)
        XCTAssertNotEqual(copy, f.source)
        XCTAssertEqual(try Data(contentsOf: copy), f.bytes)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        XCTAssertEqual(try SystemFileOperations().inspect(f.source), original)
        XCTAssertEqual(version.sha256, digest(f.bytes))
    }
    func testSymlinkAndDirectorySourcesAreRejected() async throws {
        let f = try StoreFixture()
        let link = f.source.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        for path in [link, f.source.deletingLastPathComponent()] {
            do { _ = try await f.makeStore().importMaterial(.file(path, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("Unsafe input accepted") } catch {}
        }
    }
    func testSnapshotWriteFailureNeverReportsImported() async throws {
        let f = try StoreFixture()
        do { _ = try await f.makeStore(files: FaultFiles(.snapshotWrite)).importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("Reported import despite state failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("state.json").path))
    }
    func testSourceChangesDuringCopyIsRejected() async throws {
        let f = try StoreFixture()
        do { _ = try await f.makeStore(files: FaultFiles(.mutateSource)).importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("Changed source accepted") } catch { XCTAssertEqual(error as? StoreError, .sourceChanged) }
    }
    func testSameSourceSameBytesIsDuplicateButDifferentSourceRetainsSource() async throws {
        let f = try StoreFixture()
        let store = f.makeStore()
        let first = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        guard case .hanging(let id) = first.disposition else { return XCTFail("Initial import failed") }
        let again = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertEqual(again.disposition, .duplicate(id))
        let second = f.source.deletingLastPathComponent().appendingPathComponent("different-source.txt")
        try f.bytes.write(to: second)
        let distinct = try await store.importMaterial(.file(second, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertEqual(distinct.snapshot.materials.count, 2)
        XCTAssertEqual(distinct.snapshot.materials.last?.source.filePath, second.path)
    }
    func testSystemTmpAliasWorksWithoutWeakeningOwnedBoundary() async throws {
        let f = try StoreFixture()
        let root = URL(fileURLWithPath: "/tmp/inkpeg-tests-alias-" + UUID().uuidString + "/owned", isDirectory: true)
        let store = MaterialStore(root: root, files: FaultFiles(), budget: f.budget)
        let result = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertEqual(result.snapshot.materials.count, 1)
    }
    func testOwnedRootSymlinkIsRejectedAtFileOperation() async throws {
        let f = try StoreFixture()
        let external = f.source.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: external)
        do { _ = try await f.makeStore().load(); XCTFail("Owned root redirect accepted") } catch { XCTAssertEqual(error as? StoreError, .invalidPath) }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testOwnedMaterialsSubdirectorySymlinkIsRejected() async throws {
        let f = try StoreFixture()
        let store = f.makeStore()
        _ = try await store.load()
        let folder = f.root.appendingPathComponent("Materials")
        try FileManager.default.moveItem(at: folder, to: f.root.appendingPathComponent("Materials.evidence"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: f.source.deletingLastPathComponent())
        do { _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("Owned child redirect accepted") } catch { XCTAssertEqual(error as? StoreError, .invalidPath) }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testCopyFailureKeepsOriginalAndEmptyState() async throws {
        let f = try StoreFixture()
        let store = f.makeStore(files: FaultFiles(.copy))
        do { _ = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3); XCTFail("Copy failure ignored") } catch {}
        let state = try await store.load()
        XCTAssertTrue(state.materials.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testAllPinnedFullShelfDoesNotCopyIncoming() async throws {
        let f = try StoreFixture()
        let store = f.makeStore()
        var snapshot = WorkspaceSnapshot()
        for index in 0..<3 {
            let source = f.source.deletingLastPathComponent().appendingPathComponent("source-" + String(index) + ".txt")
            try f.bytes.write(to: source)
            snapshot = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        }
        for index in snapshot.materials.indices { snapshot.materials[index].pinned = true }
        try JSONEncoder().encode(snapshot).write(to: f.root.appendingPathComponent("state.json"))
        let result = try await f.makeStore(files: FaultFiles(.copy)).importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        XCTAssertEqual(result.disposition, .shelfFull)
        XCTAssertEqual(result.snapshot, snapshot)
    }

    func testReadOnlyPayloadResolvesOnlyValidatedOwnedVersion() async throws {
        let f = try StoreFixture()
        let store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let payload = try await store.payloadURL(of: id)
        XCTAssertNotEqual(payload, f.source)
        XCTAssertEqual(try Data(contentsOf: payload), f.bytes)
        try Data("modified owned version".utf8).write(to: payload)
        do { _ = try await store.payloadURL(of: id); XCTFail("Modified immutable version accepted") } catch { XCTAssertEqual(error as? StoreError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }

    func testPDFImportPreservesBytesAndDoesNotGuessPageLocator() async throws {
        let f = try StoreFixture()
        let data = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        let bytes = data as Data
        let source = f.source.deletingLastPathComponent().appendingPathComponent("synthetic.pdf")
        try bytes.write(to: source)
        let before = try SystemFileOperations().inspect(source)
        let result = try await MaterialStore(root: f.root, files: FaultFiles(), budget: StorageBudget(maxFileBytes: 65536, maxMaterialBytes: 131072, minimumFreeBytes: 0)).importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        XCTAssertEqual(record.kind, .pdf)
        XCTAssertNil(record.source.locator)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try SystemFileOperations().inspect(source), before)
        XCTAssertEqual(record.activeVersion?.sha256, digest(bytes))
    }

}
