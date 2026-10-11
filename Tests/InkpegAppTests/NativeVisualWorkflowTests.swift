import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class NativeVisualWorkflowTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor func testSourceDisclosureRetainsDraftAndSingleSavePersistsWhileCollapsed() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-visual-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.text("Synthetic body", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        await line.render(imported.snapshot)
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: TextEditorController(line: line))
        try await detail.open(try XCTUnwrap(imported.snapshot.materials.first?.id), present: false)
        let window = try XCTUnwrap(detail.window), content = try XCTUnwrap(window.contentView)
        let disclosure = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sourceDisclosure" })
        let fields = descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 5); XCTAssertTrue(fields[1].isHiddenOrHasHiddenAncestor)
        disclosure.performClick(nil); content.layoutSubtreeIfNeeded()
        XCTAssertFalse(fields[1].isHiddenOrHasHiddenAncestor)
        let longTitle = String(repeating: "Saved title · ", count: 30).trimmingCharacters(in: .whitespaces)
        fields[0].stringValue = longTitle; fields[1].stringValue = "Saved source"
        disclosure.performClick(nil)
        XCTAssertTrue(fields[1].isHiddenOrHasHiddenAncestor); XCTAssertTrue(detail.hasUnsavedChanges)
        line.setPrivacyHidden(true); await line.waitForPrivacyPersistence()
        XCTAssertTrue(fields[0].isHiddenOrHasHiddenAncestor)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.width, 700, "Privacy must not expand the window to a long title intrinsic width")
        line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.width, 700)
        XCTAssertEqual(fields[0].stringValue, longTitle)
        XCTAssertEqual(fields[1].stringValue, "Saved source"); XCTAssertTrue(fields[1].isHiddenOrHasHiddenAncestor)
        try await detail.save()
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.first?.title, longTitle); XCTAssertEqual(saved.materials.first?.source.manualTitle, "Saved source")
        window.orderOut(nil)
    }
}

extension NativeVisualWorkflowTests {
    @MainActor func testEntryHintDismissesOnlyAfterActionAndPersistsInInjectedSuite() async throws {
        let name = "InkpegVisualHint-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let line = Line(store: MaterialStore(root: root), hintDefaults: defaults)
        try await line.load(); line.revealed = true; line.canOpenIntakeSettings = true
        XCTAssertTrue(line.showsEntryHint)
        line.dropCount = 2; XCTAssertFalse(line.showsEntryHint); line.dropCount = 0
        line.inputFeedback = "Busy"; XCTAssertFalse(line.showsEntryHint); line.inputFeedback = ""
        line.setPrivacyHidden(true); XCTAssertFalse(line.showsEntryHint)
        line.dismissEntryHint(); XCTAssertFalse(line.entryHintDismissed)
        await line.waitForPrivacyPersistence(); line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        XCTAssertTrue(line.showsEntryHint)
        var called = 0; line.onNewNote = { called += 1 }; line.onNewNote()
        XCTAssertEqual(called, 1); XCTAssertFalse(line.showsEntryHint)
        let reopened = Line(store: line.store, hintDefaults: defaults)
        reopened.revealed = true; reopened.canOpenIntakeSettings = true
        XCTAssertFalse(reopened.showsEntryHint)
        let another = Line(store: line.store, hintDefaults: try XCTUnwrap(UserDefaults(suiteName: name + "-other")))
        another.revealed = true; another.canOpenIntakeSettings = true
        XCTAssertTrue(another.showsEntryHint)
    }
}

extension NativeVisualWorkflowTests {
    @MainActor func testSettingsPrivacyContentSwapPreservesUsableMinimumSize() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-settings-size-" + UUID().uuidString)
        let line = Line(store: MaterialStore(root: root)); try await line.load()
        let controller = IntakeSettingsController(service: ClipboardImportService(gateway: VisualTestClipboard(), store: line.store), capture: CaptureFolderCoordinator(store: line.store), libraryURL: root, store: line.store, line: line)
        let window = try XCTUnwrap(controller.window)
        for hidden in [false, true, false] {
            line.setPrivacyHidden(hidden); await line.waitForPrivacyPersistence()
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(window.minSize.width, 500, "Replacing the hosted content must not reset the usable window minimum")
            XCTAssertGreaterThanOrEqual(window.minSize.height, 480)
        }
        window.orderOut(nil)
    }
}
@MainActor private final class VisualTestClipboard: ClipboardGateway {
    var changeCount: Int { 0 }
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 0, requests: []) }
}
