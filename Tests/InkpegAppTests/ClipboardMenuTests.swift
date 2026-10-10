import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class ClipboardMenuTests: XCTestCase {
    @MainActor
    func testDiscardingClipboardCannotBypassAnOpenMarkupDraft() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-termination-tests-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let first = try await store.importMaterial(.imageData(png, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 1)
        let session = try await store.createDerivedVersion(of: try XCTUnwrap(first.snapshot.materials.first?.id), kind: .markup)
        var pinned = try await store.load(); pinned.materials[0].pinned = true
        try JSONEncoder().encode(pinned).write(to: root.appendingPathComponent("state.json"), options: .atomic)
        let clipboard = ClipboardImportService(gateway: TerminationClipboard(), store: MaterialStore(root: root), capacity: { 1 })
        try await store.setClipboardEnabled(true)
        await clipboard.start()
        XCTAssertEqual(clipboard.pendingCount, 1)
        let markup = Markup(launchEditor: { _ in })
        markup.edit(session, store: store) { _ in }
        let delegate = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root))
        let reply = delegate.requestTermination(markup: markup, clipboard: clipboard, respond: { _ in .alertThirdButtonReturn })
        XCTAssertEqual(reply, .terminateCancel, "Discarding unsaved clipboard inputs must never bypass the existing editor protection")
        XCTAssertEqual(clipboard.pendingCount, 1)
        XCTAssertTrue(markup.isEditing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.workingURL.path))
    }
    @MainActor
    func testAutomaticClipboardIntakeHasDiscoverablePauseMenu() {
        let previous = appLocalizer
        appLocalizer = Localizer(localeIdentifier: "zh-Hans")
        defer { appLocalizer = previous }
        let root = URL(fileURLWithPath: "/tmp/inkpeg-menu-tests-" + UUID().uuidString)
        let delegate = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root))
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "暂停剪贴板自动挂入" }, "Automatic intake must expose a pause control independently of capture folder selection")
    }
}

@MainActor private final class TerminationClipboard: ClipboardGateway {
    var changeCount = 1
    func readSnapshot() throws -> ClipboardContents {
        ClipboardContents(revision: 1, requests: [.text("待处理合成输入", SourceRecord(origin: .clipboard))])
    }
}
