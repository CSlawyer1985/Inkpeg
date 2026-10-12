import XCTest
@testable import InkpegCore
final class ExportSafetyTests: XCTestCase {
    func testExportPreservesSourceAndVersionAndRefusesCollision() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let before = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let id = try XCTUnwrap(before.materials.first?.id)
        let destination = f.source.deletingLastPathComponent().appendingPathComponent("export.txt")
        let exported = try await store.exportCopy(of: id, to: destination)
        XCTAssertEqual(exported, destination.standardizedFileURL)
        try Data("receiver edit".utf8).write(to: exported)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        let managed = try await store.payloadURL(of: id), loaded = try await store.load()
        XCTAssertEqual(try Data(contentsOf: managed), f.bytes)
        XCTAssertEqual(loaded, before)
        do { _ = try await store.exportCopy(of: id, to: destination); XCTFail("Must not overwrite") } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("receiver edit".utf8))
    }
    func testExportCannotTargetSourceManagedVersionOrSymlink() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let before = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let id = try XCTUnwrap(before.materials.first?.id), managed = try await store.payloadURL(of: id)
        let link = f.source.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        for destination in [f.source, managed, link] {
            do { _ = try await store.exportCopy(of: id, to: destination); XCTFail("Unsafe export") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
        XCTAssertEqual(try Data(contentsOf: managed), f.bytes)
    }
}
extension ExportSafetyTests {
    func testHiddenSourceExportsVisibleCopiesWithoutChangingSourceOrLibrary() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        var source = f.source
        var hidden = URLResourceValues(); hidden.isHidden = true
        try source.setResourceValues(hidden)
        let before = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let id = try XCTUnwrap(before.materials.first?.id), managed = try await store.payloadURL(of: id)
        XCTAssertEqual(try managed.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        for destination in [f.root.appendingPathComponent("Exports/ready/source.txt"),
                            source.deletingLastPathComponent().appendingPathComponent("finder-copy.txt")] {
            let exported = try await store.exportCopy(of: id, to: destination)
            XCTAssertEqual(try exported.resourceValues(forKeys: [.isHiddenKey]).isHidden, false,
                           "An exported file must appear normally in Finder, even when its managed source is hidden")
            XCTAssertEqual(try Data(contentsOf: exported), f.bytes)
        }
        XCTAssertEqual(try source.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        XCTAssertEqual(try managed.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        let after = try await store.load(); XCTAssertEqual(after, before)
    }
    func testExportBindsToSelectedVersionAcrossLaterEdit() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try Data("new version".utf8).write(to: session.workingURL)
        _ = try await store.finishEditing(session, result: .save(session.workingURL))
        let destination = f.source.deletingLastPathComponent().appendingPathComponent("bound-original.txt")
        _ = try await store.exportCopy(of: record.id, versionID: record.activeVersionID, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), f.bytes)
    }
}
