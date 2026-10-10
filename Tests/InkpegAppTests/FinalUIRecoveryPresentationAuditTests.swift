import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class FinalUIRecoveryPresentationAuditTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor func testExplicitOlderDraftResumeShowsVersionChangeWithoutReplacingCurrentMaterial() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-final-resume-synthetic-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.text("合成原始摘录", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let older = try await store.createDerivedVersion(of: id, kind: .textEdit)
        let retained = "明确恢复的旧未完成正文"
        try await store.writeEditingResult(older, data: Data(retained.utf8))
        let newer = try await store.createDerivedVersion(of: id, kind: .textEdit)
        try await store.writeEditingResult(newer, data: Data("已提交的较新材料正文".utf8))
        let current = try await store.finishEditing(newer, result: .save(newer.workingURL))
        await line.render(current)
        let editor = TextEditorController(line: line)
        try await editor.resume(older, present: false)
        let recovered = try XCTUnwrap(editor.session)
        XCTAssertEqual(recovered.id, older.id)
        XCTAssertEqual(recovered.baseVersionID, current.materials.first?.activeVersionID)
        XCTAssertEqual(editor.text, retained)
        let visibleText = descendants(try XCTUnwrap(editor.window?.contentView)).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(visibleText.contains(L(.textRecoveryChanged)), "The native editor must identify explicit recovery against a newer material version")
        let after = try await store.load()
        XCTAssertEqual(after.materials, current.materials)
        let payload = try await store.payloadURL(of: id)
        XCTAssertEqual(try String(contentsOf: payload), "已提交的较新材料正文")
        XCTAssertEqual(try String(contentsOf: recovered.workingURL), retained)
        try await editor.cancel()
    }
    @MainActor func testSameBaseResumeKeepsOrdinaryHelpAndRetainedBody() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-final-resume-same-base-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.text("合成原始摘录", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let session = try await store.createDerivedVersion(of: id, kind: .textEdit)
        try await store.writeEditingResult(session, data: Data("同版本恢复正文".utf8))
        let editor = TextEditorController(line: line)
        try await editor.resume(session, present: false)
        XCTAssertEqual(editor.session, session); XCTAssertEqual(editor.text, "同版本恢复正文")
        let visibleText = descendants(try XCTUnwrap(editor.window?.contentView)).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(visibleText.contains(L(.textEditorHelp)))
        XCTAssertFalse(visibleText.contains(L(.textRecoveryChanged)))
        try await editor.cancel()
    }
}
