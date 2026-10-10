import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class MarkupRecoveryTests: XCTestCase {
    @MainActor
    func testOlderImageDraftCanSaveAfterExplicitRecoveryWithoutChangingPriorVersions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-markup-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let source = root.appendingPathComponent("source.png")
        try png.write(to: source)
        let store = MaterialStore(root: root.appendingPathComponent("owned")), line = Line(store: store)
        let imported = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let older = try await store.createDerivedVersion(of: record.id, kind: .markup)
        let newer = try await store.createDerivedVersion(of: record.id, kind: .markup)
        try await store.writeEditingResult(newer, data: gif)
        let current = try await store.finishEditing(newer, result: .save(newer.workingURL))
        await line.render(current)
        let pending = try await store.pendingEditSessions()
        XCTAssertTrue(pending.contains(older))
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root.appendingPathComponent("owned")))
        let resumed = try await recovery.prepareMarkupRecovery(older)
        XCTAssertEqual(resumed.id, older.id)
        XCTAssertEqual(resumed.workingURL, older.workingURL)
        XCTAssertEqual(resumed.baseVersionID, current.materials.first?.activeVersionID)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), png)
        let beforeSave = try await store.load()
        var anchored = current
        anchored.generation += 1 // Recovery durably anchors the current version before rebasing the draft.
        XCTAssertEqual(beforeSave, anchored, "Recovery may advance only the anchor generation, preserving all material fields")
        let saved = try await store.finishEditing(resumed, result: .save(resumed.workingURL))
        XCTAssertEqual(saved.materials.first?.versions.count, 3)
        let originalCopy = try await store.payloadURL(of: record.id, versionID: record.activeVersionID)
        let priorCopy = try await store.payloadURL(of: record.id, versionID: current.materials.first?.activeVersionID)
        XCTAssertEqual(try Data(contentsOf: originalCopy), png)
        XCTAssertEqual(try Data(contentsOf: priorCopy), gif)
        let activeCopy = try await store.payloadURL(of: record.id)
        XCTAssertEqual(try Data(contentsOf: activeCopy), png)
        XCTAssertEqual(try Data(contentsOf: source), png)
    }
}
