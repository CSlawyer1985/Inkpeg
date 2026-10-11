import XCTest
import AppKit
import Combine
import InkpegCore
@testable import Inkpeg

final class PrivacyWorkflowTests: XCTestCase {
    private let renderDirectory: URL = {
        if let configured = ProcessInfo.processInfo.environment["INKPEG_PRIVACY_EVIDENCE_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-privacy-render-" + UUID().uuidString, isDirectory: true)
    }()
    @MainActor func testRecoveryWindowClosesImmediatelyOnPrivacy() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-privacy-workflow-" + UUID().uuidString)
        let line = Line(store: MaterialStore(root: root))
        try await line.load()
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))))
        await recovery.show()
        let owned = NSApp.windows.filter { $0.title == L(.reviewPendingTitle) }
        XCTAssertFalse(owned.isEmpty)
        var snapshot = line.snapshot; snapshot.privacyHidden = true
        await line.render(snapshot)
        XCTAssertTrue(owned.allSatisfy { !$0.isVisible }, "Recovery content must disappear immediately")
        owned.forEach { $0.orderOut(nil) }
    }
}

extension PrivacyWorkflowTests {
    @MainActor private func fixture(files: FileOperations = SystemFileOperations()) async throws -> (URL, Line, UUID) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-privacy-workflow-" + UUID().uuidString)
        let line = Line(store: MaterialStore(root: root, files: files))
        let imported = try await line.store.importMaterial(.text("SYNTHETIC_PRIVATE_BODY", SourceRecord(origin: .clipboard, manualTitle: "SYNTHETIC_PRIVATE_SOURCE")), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        await line.render(imported.snapshot)
        return (root, line, try XCTUnwrap(imported.snapshot.materials.first?.id))
    }
    @MainActor func testImmediateCoverFailedWriteStaleLoadAndExplicitRetry() async throws {
        let files = PrivacyWorkflowFiles()
        let (root, line, _) = try await fixture(files: files)
        let stale = line.snapshot
        line.keyboardID = line.items.first?.id
        files.failState = true
        line.setPrivacyHidden(true)
        XCTAssertTrue(line.snapshot.privacyHidden); XCTAssertTrue(line.items.isEmpty)
        await line.waitForPrivacyPersistence()
        XCTAssertTrue(line.privacySaveFailed); XCTAssertFalse(line.privacySaving)
        let disk = try await MaterialStore(root: root).load()
        XCTAssertFalse(disk.privacyHidden, "Failed disk writes must not be reported as saved")
        await line.render(stale); try await line.load()
        XCTAssertTrue(line.snapshot.privacyHidden); XCTAssertTrue(line.items.isEmpty)
        files.failState = false
        line.retryPrivacyPersistence(); await line.waitForPrivacyPersistence()
        XCTAssertFalse(line.privacySaveFailed)
        let restarted = Line(store: MaterialStore(root: root))
        let startupHost = LineHostingView(line: restarted)
        startupHost.frame = NSRect(x: 0, y: 0, width: 980, height: 210)
        var publishedVisibleCards = false
        let observation = restarted.$items.sink { if !$0.isEmpty { publishedVisibleCards = true } }
        defer { observation.cancel() }
        try await restarted.load(); startupHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(restarted.snapshot.privacyHidden); XCTAssertTrue(restarted.items.isEmpty)
        XCTAssertFalse(publishedVisibleCards, "A private startup must never publish a sensitive first frame")
        XCTAssertTrue(startupHost.cardViews.isEmpty)
        await restarted.render(stale)
        XCTAssertTrue(restarted.snapshot.privacyHidden, "A stale load must never reveal a private startup")
        files.failState = true
        line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        XCTAssertTrue(line.snapshot.privacyHidden); XCTAssertTrue(line.privacySaveFailed)
        files.failState = false
        line.retryPrivacyPersistence(); await line.waitForPrivacyPersistence()
        XCTAssertFalse(line.snapshot.privacyHidden); XCTAssertEqual(line.keyboardID, stale.materials.first?.id)
    }
    @MainActor func testOldRealDragProviderNeverRevivesAfterHideAndReveal() async throws {
        let (root, line, _) = try await fixture()
        let board = NSPasteboard(name: .init("InkpegPrivacyProvider-" + UUID().uuidString))
        board.setString("unrelated clipboard", forType: .string)
        let actions = MaterialActions(line: line, root: root, pasteboard: board)
        let provider = try await actions.dragProvider(try XCTUnwrap(line.items.first))
        XCTAssertNotNil(provider.pasteboardPropertyList(forType: .string))
        line.setPrivacyHidden(true); await line.waitForPrivacyPersistence()
        line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        XCTAssertFalse(line.snapshot.privacyHidden)
        XCTAssertNil(provider.pasteboardPropertyList(forType: .string))
        XCTAssertTrue(provider.writableTypes(for: board).isEmpty)
        XCTAssertEqual(board.string(forType: .string), "unrelated clipboard")
        let fresh = try await actions.dragProvider(try XCTUnwrap(line.items.first))
        XCTAssertNotNil(fresh.pasteboardPropertyList(forType: .string))
    }
    @MainActor func testOwnedModalResponseCannotExportAfterHide() async throws {
        let (_, line, _) = try await fixture()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SYNTHETIC_PRIVATE_FILE"
        let response = line.runModal(panel) {
            line.setPrivacyHidden(true)
            return .OK // Simulates a late accepted response after cancellation.
        }
        XCTAssertEqual(response, .cancel); XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.title, L(.contentHidden)); XCTAssertNil(panel.representedURL)
        await line.waitForPrivacyPersistence()
        let alert = NSAlert(); alert.informativeText = "SYNTHETIC_PRIVATE_ERROR"
        var invoked = false
        XCTAssertEqual(line.runModal(alert.window) { invoked = true; return .alertFirstButtonReturn }, .cancel)
        XCTAssertFalse(invoked)
    }
    @MainActor func testDetailLateDiscardChoiceCannotCloseOrLoseDraft() async throws {
        let (root, line, id) = try await fixture()
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: TextEditorController(line: line))
        try await detail.open(id, present: false)
        let fields = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        fields[0].stringValue = "SYNTHETIC_PRIVATE_DRAFT"
        detail.chooseUnsavedChanges = { line.setPrivacyHidden(true); return .discard }
        try await detail.dismiss()
        XCTAssertNotNil(detail.window); XCTAssertTrue(detail.hasUnsavedChanges)
        XCTAssertEqual(fields[0].stringValue, "SYNTHETIC_PRIVATE_DRAFT")
        await line.waitForPrivacyPersistence()
        line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        XCTAssertTrue(detail.hasUnsavedChanges); XCTAssertTrue(fields[0].isEditable)
        detail.window?.orderOut(nil)
    }
    @MainActor func testOwnedEditorAndSettingsRenderAndAccessibilityAreCoveredWithoutLosingDrafts() async throws {
        let (root, line, id) = try await fixture()
        let note = NoteEditorController(line: line); try await note.openNew(present: false)
        note.textView.string = "SYNTHETIC_PRIVATE_NOTE"; note.textDidChange(Notification(name: NSText.didChangeNotification))
        let text = TextEditorController(line: line); try await text.open(id, present: false)
        text.text = "SYNTHETIC_PRIVATE_TEXT_DRAFT"
        let session = text.session
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: text)
        try await detail.open(id, present: false)
        let service = ClipboardImportService(gateway: PrivacyEmptyClipboard(), store: line.store)
        let settings = IntakeSettingsController(service: service, capture: CaptureFolderCoordinator(store: line.store), libraryURL: root.appendingPathComponent("SYNTHETIC_PRIVATE_PATH"), store: line.store, line: line)
        settings.model.page = 1
        line.canOpenIntakeSettings = true; line.revealed = true
        let host = LineHostingView(line: line); host.frame = NSRect(x: 0, y: 0, width: 980, height: 210)
        let shelf = LinePanel(content: host); shelf.setContentSize(NSSize(width: 980, height: 210))
        host.layoutSubtreeIfNeeded()
        let cards = host.cardViews
        XCTAssertFalse(cards.isEmpty, "A real existing card host must be present")
        for window in [note.window, text.window, detail.window, settings.window].compactMap({ $0 }) {
            window.setContentSize(NSSize(width: 700, height: 480)); window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        try render(try XCTUnwrap(text.window?.contentView), name: "visible-text")
        line.setPrivacyHidden(true)
        XCTAssertTrue(cards.allSatisfy { $0.isHidden })
        XCTAssertTrue(host.accessibilityChildren()?.isEmpty == true)
        let windows = try [note.window, text.window, detail.window, settings.window].map { try XCTUnwrap($0) }
        for (index, window) in windows.enumerated() {
            XCTAssertEqual(window.title, L(.contentHidden)); XCTAssertNil(window.representedURL)
            window.setContentSize(NSSize(width: 700, height: 480))
            let view = try XCTUnwrap(window.contentView); view.layoutSubtreeIfNeeded()
            XCTAssertFalse(accessibilityText(view).contains("SYNTHETIC_PRIVATE"))
            try render(view, name: "covered-\(index)")
        }
        XCTAssertFalse(host.isHidden)
        XCTAssertTrue(host.cardViews.isEmpty, "Sensitive hosts must leave the actual rendered tree synchronously")
        let input = try XCTUnwrap(descendants(host).compactMap { $0 as? LineDropTarget }.first)
        let button = try XCTUnwrap(input.subviews.compactMap { $0 as? NSButton }.first)
        let parent = try XCTUnwrap(host.superview)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: parent.superview)
        XCTAssertTrue(parent.hitTest(point) === button, "The real parent must still route to the non-sensitive rope control")
        try render(parent, name: "covered-shelf")
        XCTAssertFalse(note.textView.isSelectable); XCTAssertFalse(text.textView.isSelectable)
        await line.waitForPrivacyPersistence()
        line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        XCTAssertEqual(note.textView.string, "SYNTHETIC_PRIVATE_NOTE")
        XCTAssertEqual(text.text, "SYNTHETIC_PRIVATE_TEXT_DRAFT"); XCTAssertEqual(text.session, session)
        XCTAssertTrue(text.textView.isEditable); XCTAssertTrue(note.textView.isEditable)
        windows.forEach { $0.orderOut(nil) }; shelf.orderOut(nil)
    }

    @MainActor func testCopyAndDetailReadFinishingAfterHideCannotPublishOrOpen() async throws {
        for detailRead in [false, true] {
            let files = PrivacyWorkflowFiles()
            let (root, line, id) = try await fixture(files: files)
            let board = NSPasteboard(name: .init(UUID().uuidString)); board.setString("KEEP_UNRELATED", forType: .string)
            let actions = MaterialActions(line: line, root: root, pasteboard: board)
            let detail = MaterialDetailController(line: line, actions: actions, editor: TextEditorController(line: line))
            files.readHook = {
                let signal = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { line.setPrivacyHidden(true); signal.signal() }
                guard signal.wait(timeout: .now() + 3) == .success else { throw StoreError.operationInProgress }
            }
            do {
                if detailRead { try await detail.open(id, present: false) } else { try await actions.copy(id) }
                if !detailRead { XCTFail("A late copy must fail closed") }
            } catch { XCTAssertEqual(error as? StoreError, .invalidSource) }
            XCTAssertEqual(files.readHookHits, 1)
            await line.waitForPrivacyPersistence()
            line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
            XCTAssertNil(detail.window); XCTAssertEqual(board.string(forType: .string), "KEEP_UNRELATED")
        }
    }
    @MainActor func testRunningFlightPanelIsClearedImmediatelyAndNeverReappears() async throws {
        let (_, line, _) = try await fixture()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.cgImage)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        var completed = false
        CaptureFlight.fly(image: image, from: CGRect(x: 20, y: 20, width: 80, height: 80), to: CGRect(x: 20, y: 180, width: 80, height: 80), tilt: 0, on: screen) { completed = true }
        let windows = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
        XCTAssertFalse(windows.isEmpty); XCTAssertTrue(windows.contains { $0.isVisible })
        func imageLayers(_ layer: CALayer) -> [CALayer] { (layer.contents == nil ? [] : [layer]) + (layer.sublayers ?? []).flatMap(imageLayers) }
        let layers = windows.flatMap { $0.contentView?.layer.map(imageLayers) ?? [] }
        XCTAssertFalse(layers.isEmpty)
        line.setPrivacyHidden(true)
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible }); XCTAssertTrue(layers.allSatisfy { $0.contents == nil })
        await line.waitForPrivacyPersistence()
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertFalse(completed); XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
    }

    @MainActor func testRunningNativeAlertIsAbortedByPrivacy() async throws {
        let (_, line, _) = try await fixture()
        let alert = NSAlert(); alert.messageText = "SYNTHETIC_PRIVATE_ALERT"; alert.addButton(withTitle: "OK")
        var fired = false
        let timer = Timer(timeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated { fired = true; line.setPrivacyHidden(true) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let response = line.runAlert(alert)
        XCTAssertTrue(fired); XCTAssertEqual(response, .cancel)
        XCTAssertFalse(alert.window.isVisible); XCTAssertTrue(alert.window.contentView?.isHidden == true)
        XCTAssertEqual(alert.window.title, L(.contentHidden))
        await line.waitForPrivacyPersistence()
    }
    @MainActor func testSettingsOwnedCleanupSheetIsClosedSynchronously() async throws {
        let (root, line, _) = try await fixture()
        let service = ClipboardImportService(gateway: PrivacyEmptyClipboard(), store: line.store)
        let settings = IntakeSettingsController(service: service, capture: CaptureFolderCoordinator(store: line.store), libraryURL: root, store: line.store, line: line)
        let window = try XCTUnwrap(settings.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = NSTextField(labelWithString: "SYNTHETIC_PRIVATE_STAGING")
        window.beginSheet(sheet, completionHandler: { _ in })
        XCTAssertTrue(window.attachedSheet === sheet)
        line.setPrivacyHidden(true)
        XCTAssertFalse(sheet.isVisible); XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(settings.model.showCleanup); XCTAssertNil(settings.model.cleanupPlan)
        await line.waitForPrivacyPersistence(); window.orderOut(nil)
    }
    @MainActor func testRecoveryRefreshAcrossPrivacyCycleCannotAutoShow() async throws {
        let files = PrivacyWorkflowFiles()
        let (root, line, id) = try await fixture(files: files)
        _ = try await line.store.createDerivedVersion(of: id, kind: .textEdit)
        try Data("SYNTHETIC_ORPHAN".utf8).write(to: root.appendingPathComponent("Transactions/unknown.stage"))
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))))
        let entered = expectation(description: "Refresh is inside the real pending-draft read")
        let release = DispatchSemaphore(value: 0)
        files.readHook = {
            entered.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw StoreError.unavailableSpace }
        }
        let work = Task { await recovery.refresh(showIfNeeded: true) }
        await fulfillment(of: [entered], timeout: 3)
        line.setPrivacyHidden(true); line.setPrivacyHidden(false)
        // Queue the explicit reveal behind the blocked store query before release.
        try await Task.sleep(nanoseconds: 20_000_000)
        release.signal()
        await line.waitForPrivacyPersistence(); await work.value
        XCTAssertFalse(line.snapshot.privacyHidden); XCTAssertEqual(files.readHookHits, 1)
        XCTAssertTrue(recovery.hasDrafts)
        XCTAssertNil(recovery.window, "The pre-hide refresh must not acquire a new epoch through show()")
        recovery.window?.orderOut(nil)
        await recovery.refresh(showIfNeeded: true)
        XCTAssertTrue(recovery.window?.isVisible == true, "A fresh explicit refresh may still show retained work")
        recovery.window?.orderOut(nil)
    }

    @MainActor func testRecoveryMarkupCompletionAfterPrivacyCycleSavesWithoutReopening() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-privacy-recovery-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let original = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let imported = try await store.importMaterial(.imageData(original, SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        let session = try await store.createDerivedVersion(of: record.id, kind: .markup)
        await line.render(imported.snapshot)
        let launched = expectation(description: "The actual resume button launches the recovered draft")
        let suspended = expectation(description: "Returned image save is suspended")
        var release: CheckedContinuation<Void, Never>?
        var writes = 0, failWrite = true, failures = 0
        let markup = Markup(launchEditor: { url in XCTAssertEqual(url, session.workingURL); launched.fulfill() }, reportFailure: { failures += 1 }, persistResult: { session, store, data in
            writes += 1
            if writes == 1 { await withCheckedContinuation { release = $0; suspended.fulfill() } }
            if failWrite { throw StoreError.unavailableSpace }
            try await store.writeEditingResult(session, data: data)
        })
        markup.privacyLine = line
        let recovery = WorkflowRecoveryController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), markup: markup)
        await recovery.show()
        let owned = try XCTUnwrap(recovery.window)
        let resume = try XCTUnwrap(descendants(try XCTUnwrap(owned.contentView)).compactMap { $0 as? ActionButton }.first { $0.title == L(.resumeDraft) })
        resume.performClick(nil)
        await fulfillment(of: [launched], timeout: 3)
        let returned = root.appendingPathComponent("returned.gif")
        try ImageBudgetFixtures.twoFrameGIF.write(to: returned)
        let work = Task { await markup.receive([returned]) }
        await fulfillment(of: [suspended], timeout: 3)
        line.setPrivacyHidden(true); await line.waitForPrivacyPersistence()
        line.setPrivacyHidden(false); await line.waitForPrivacyPersistence()
        XCTAssertFalse(line.snapshot.privacyHidden); XCTAssertNil(recovery.window)
        release?.resume(); await work.value
        XCTAssertEqual(failures, 1); XCTAssertTrue(markup.canRetrySaving); XCTAssertTrue(markup.hasPendingResult)
        let pending = try await store.pendingEditSessions()
        XCTAssertTrue(pending.contains { $0.id == session.id }); XCTAssertEqual(try Data(contentsOf: session.workingURL), original)
        XCTAssertNil(recovery.window, "Failed save must retain the draft without reopening recovery")
        failWrite = false
        await markup.retrySaving()
        // The real controller completion starts its async store transaction.
        // Observe the committed store version, then allow the queued UI continuation.
        for _ in 0..<100 {
            if try await store.load().materials.first?.versions.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(line.snapshot.materials.first?.versions.count, 1, "An old completion must not publish a new shelf presentation")
        for _ in 0..<20 where recovery.window == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(recovery.window, "The pre-hide recovery completion must not open a new window after reveal")
        XCTAssertFalse(owned.isVisible)
        let saved = try await store.load(), retained = try await store.pendingEditSessions()
        XCTAssertEqual(saved.materials.first?.versions.count, 2); XCTAssertFalse(retained.contains { $0.id == session.id })
        let active = try await store.payloadURL(of: record.id), originalURL = try await store.payloadURL(of: record.id, versionID: record.originalVersionID)
        XCTAssertEqual(try Data(contentsOf: active), ImageBudgetFixtures.twoFrameGIF); XCTAssertEqual(try Data(contentsOf: originalURL), original)
        recovery.window?.orderOut(nil)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func accessibilityText(_ object: Any) -> String {
        guard let element = object as? NSAccessibilityProtocol else { return "" }
        if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor || view.isAccessibilityHidden() { return "" }
        return [element.accessibilityLabel() ?? "", element.accessibilityValue() as? String ?? "", element.accessibilityTitle() ?? ""].joined(separator: " ") + (element.accessibilityChildren() ?? []).map(accessibilityText).joined(separator: " ")
    }
    @MainActor private func render(_ view: NSView, name: String) throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.window?.displayIfNeeded(); view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "Render \(name) bounds \(view.bounds)")
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
@MainActor private struct PrivacyEmptyClipboard: ClipboardGateway {
    var changeCount: Int { 0 }
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 0, requests: []) }
}
private final class PrivacyWorkflowFiles: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    private let lock = NSLock()
    private var failure = false
    private var readCallback: (() throws -> Void)?
    private(set) var readHookHits = 0
    var readHook: (() throws -> Void)? { get { lock.lock(); defer { lock.unlock() }; return readCallback } set { lock.lock(); defer { lock.unlock() }; readCallback = newValue } }
    var failState: Bool { get { lock.lock(); defer { lock.unlock() }; return failure } set { lock.lock(); defer { lock.unlock() }; failure = newValue } }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data {
        lock.lock(); let callback = readCallback; readCallback = nil
        if callback != nil { readHookHits += 1 }; lock.unlock()
        try callback?()
        return try base.read(url)
    }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if failState && url.lastPathComponent == "state.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
