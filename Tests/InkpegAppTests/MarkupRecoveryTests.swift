import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class MarkupRecoveryTests: XCTestCase {
    @MainActor
    func testLegacyOverlimitRecoveryAndRetryNeverLaunchEditorAndRetainDraft() async throws {
        let fixture = try await ImageBudgetFixtures.legacyStore()
        let session = try await fixture.store.createDerivedVersion(of: fixture.record.id, kind: .markup)
        let line = Line(store: fixture.store); await line.render(fixture.snapshot)
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: fixture.root))
        let resumed = try await recovery.prepareMarkupRecovery(session)
        let metadata = session.workingURL.deletingLastPathComponent().appendingPathComponent("session.json")
        let metadataBefore = try Data(contentsOf: metadata), before = try await fixture.store.load()
        var launches = 0, failures = 0, callbacks = 0
        let markup = Markup(launchEditor: { _ in launches += 1 }, reportFailure: { failures += 1 })
        markup.edit(resumed, store: fixture.store) { _ in callbacks += 1 }
        XCTAssertEqual(launches, 0, "Recovery bypasses MaterialActions and must validate the actual draft before launch")
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(markup.canRetrySaving)
        await markup.retrySaving()
        XCTAssertEqual(launches, 0, "Retry must perform admission again before any editor launch")
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(markup.isEditing)
        XCTAssertTrue(markup.canRetrySaving)
        XCTAssertEqual(try Data(contentsOf: session.workingURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: metadata), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.payload), fixture.bytes)
        let retained = try await fixture.store.load(); XCTAssertEqual(retained, before)
        let pending = try await fixture.store.pendingEditSessions(); XCTAssertTrue(pending.contains(resumed))
    }

    @MainActor
    func testExternallyEnlargedRecoveredDraftIsCheckedOnEveryLaunchAttempt() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-markup-recovery-growth-" + UUID().uuidString), store = MaterialStore(root: root), line = Line(store: store)
        let original = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let imported = try await store.importMaterial(.imageData(original, SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .markup)
        await line.render(imported.snapshot)
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root))
        let resumed = try await recovery.prepareMarkupRecovery(session)
        let oversized = try ImageBudgetFixtures.encoded()
        try oversized.write(to: resumed.workingURL) // Synthetic external editor mutation after recovery's byte/file checks.
        var launches = 0, failures = 0
        let markup = Markup(launchEditor: { _ in launches += 1 }, reportFailure: { failures += 1 })
        markup.edit(resumed, store: store) { _ in XCTFail("A rejected draft must remain pending") }
        XCTAssertEqual(launches, 0); XCTAssertEqual(failures, 1)
        await markup.retrySaving()
        XCTAssertEqual(launches, 0); XCTAssertEqual(failures, 2)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), oversized)
        let retained = try await store.load(); XCTAssertEqual(retained, imported.snapshot)
        let payload = try await store.payloadURL(of: record.id); XCTAssertEqual(try Data(contentsOf: payload), original)
        // A deliberate external repair is picked up on retry; admission does
        // not keep a stale rejection or silently replace the oversized draft.
        try original.write(to: resumed.workingURL)
        await markup.retrySaving()
        XCTAssertEqual(launches, 1); XCTAssertEqual(failures, 2)
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), original)
        let afterRepair = try await store.load(); XCTAssertEqual(afterRepair, imported.snapshot)
    }

    @MainActor
    func testAdmittedRecoveredDraftLaunchesThroughCentralGuard() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-markup-recovery-admitted-" + UUID().uuidString), store = MaterialStore(root: root), line = Line(store: store)
        let original = ImageBudgetFixtures.twoFrameGIF
        let imported = try await store.importMaterial(.imageData(original, SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(imported.snapshot.materials.first), session = try await store.createDerivedVersion(of: record.id, kind: .markup)
        await line.render(imported.snapshot)
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root))
        let resumed = try await recovery.prepareMarkupRecovery(session)
        var launched: [URL] = []
        let markup = Markup(launchEditor: { launched.append($0) }, reportFailure: { XCTFail("Admitted recovery must open normally") })
        markup.edit(resumed, store: store) { _ in }
        XCTAssertEqual(launched, [resumed.workingURL])
        await markup.retrySaving()
        XCTAssertEqual(launched.count, 1, "An active editor cannot open a second instance")
        XCTAssertEqual(try Data(contentsOf: resumed.workingURL), original)
        let retained = try await store.load(); XCTAssertEqual(retained, imported.snapshot)
    }
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
