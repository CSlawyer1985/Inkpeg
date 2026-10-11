import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class NativeEditingMenuTests: XCTestCase {
    @MainActor func testActualTextEditorInputPasteAndReplacementSupportNativeUndoRedo() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("inkpeg-text-undo-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("粘贴中文\n第二行", forType: .string)
        for (operation, savesRedone) in [("input", false), ("input", true), ("paste", false), ("paste", true), ("replace", false), ("replace", true)] {
            let store = MaterialStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-text-undo-" + UUID().uuidString))
            let line = Line(store: store)
            let imported = try await store.importMaterial(.text("原文｜保留", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            await line.render(imported.snapshot)
            let editor = TextEditorController(line: line)
            let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
            try await editor.open(id, present: false)
            defer { editor.window?.close() }
            XCTAssertTrue(try XCTUnwrap(editor.window).makeFirstResponder(editor.textView))
            let initial = editor.textView.string
            let expected: String
            editor.textView.breakUndoCoalescing()
            switch operation {
            case "paste":
                editor.textView.setSelectedRange(NSRange(location: 3, length: 2))
                XCTAssertTrue(editor.textView.readSelection(from: board, type: .string))
                expected = "原文｜粘贴中文\n第二行"
            case "replace":
                editor.textView.insertText("替换中文", replacementRange: NSRange(location: 0, length: 2))
                expected = "替换中文｜保留"
            default:
                editor.textView.insertText("输入中文", replacementRange: NSRange(location: (initial as NSString).length, length: 0))
                expected = "原文｜保留输入中文"
            }
            XCTAssertEqual(editor.textView.string, expected, operation)
            XCTAssertEqual(editor.text, expected, "The production delegate must track native editing")
            let undo = try XCTUnwrap(editor.textView.undoManager)
            XCTAssertTrue(undo.canUndo, operation)
            performNativeTextUndo(undo)
            XCTAssertEqual(editor.textView.string, initial, operation)
            XCTAssertEqual(editor.text, initial, operation)
            XCTAssertTrue(undo.canRedo, operation)
            performNativeTextUndo(undo, redo: true)
            XCTAssertEqual(editor.textView.string, expected, operation)
            XCTAssertEqual(editor.text, expected, operation)
            if !savesRedone {
                performNativeTextUndo(undo)
                XCTAssertEqual(editor.textView.string, initial, operation)
                XCTAssertEqual(editor.text, initial, operation)
            }
            let savedText = savesRedone ? expected : initial
            try await editor.save()
            let payload = try await store.payloadURL(of: id)
            XCTAssertEqual(try String(contentsOf: payload), savedText, "Saving must persist the native undo/redo result")
        }
    }

    @MainActor func testBlankAndComposingNotesCannotEnablePublish() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-button-" + UUID().uuidString))
        let line = Line(store: store); try await line.load()
        let editor = NoteEditorController(line: line); try await editor.openNew(present: false)
        defer { editor.window?.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(try XCTUnwrap(editor.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\r" })
        XCTAssertFalse(button.isEnabled)
        editor.textView.string = "可挂上的记事"; editor.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertTrue(button.isEnabled)
        editor.textView.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertFalse(button.isEnabled)
        editor.textView.unmarkText(); editor.textView.string = " \n "; editor.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertFalse(button.isEnabled)
        try await editor.flushAutosave()
    }
    @MainActor func testCommandPasteBindingUsesNativeTextSelectionWithoutChangingGeneralClipboard() throws {
        let app = NSApplication.shared, previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        app.mainMenu = nil
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-edit-menu-" + UUID().uuidString)
        let delegate: NSApplicationDelegate = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root))
        delegate.applicationWillFinishLaunching?(Notification(name: NSApplication.willFinishLaunchingNotification, object: app))
        let board = NSPasteboard(name: .init("inkpeg-edit-menu-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("粘贴的中文\n第二行", forType: .string)
        let view = NamedPasteTextView(board: board)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(); scroll.documentView = view
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))
        // XCTest has no running NSApplication event loop/key window. Check the
        // installed binding with an explicit real text target here; the nil-
        // target first-responder route is verified in the running native App.
        guard let paste = app.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }).first(where: { $0.action == #selector(NSText.paste(_:)) }) else {
            XCTFail("The app must install a paste binding"); return
        }
        XCTAssertNil(paste.target, "Production commands must resolve the active responder")
        paste.target = view
        view.string = "前面保留｜替换这段｜后面保留"
        view.setSelectedRange(NSRange(location: 5, length: 4))
        XCTAssertEqual(view.string, "前面保留｜替换这段｜后面保留")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(app.mainMenu?.performKeyEquivalent(with: event) == true, "The app must route Command-V through its editing menu")
        XCTAssertEqual(view.string, "前面保留｜粘贴的中文\n第二行｜后面保留")
    }

    @MainActor func testSwitchingDraftsClearsUndoHistory() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-undo-" + UUID().uuidString))
        let line = Line(store: store); try await line.load()
        let editor = NoteEditorController(line: line)
        try await editor.openNew(present: false)
        defer { editor.window?.close() }
        editor.textView.insertText("第一张记事", replacementRange: NSRange(location: 0, length: 0))
        try await editor.flushAutosave()
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        let next = try await store.createNoteDraft()
        try await editor.resume(next, present: false)
        XCTAssertFalse(editor.textView.undoManager?.canUndo == true, "A new draft cannot undo edits from another draft")
        XCTAssertEqual(editor.textView.string, "")
    }

    func testStorageUsageFailsForUnreadableFolderAndDescendant() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-usage-permission-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Materials"), nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nested.appendingPathComponent("file"))
        XCTAssertEqual(IntakeSettingsModel.measureUsage(root)?["Materials"], 7)
        for unreadable in [folder, nested, root] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
            XCTAssertNil(IntakeSettingsModel.measureUsage(root), "Unreadable directory must not look empty")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        }
    }

    @MainActor func testPlainTextPasteIntoActualNoteAutosavesAndSurvivesReopening() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-paste-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        try await line.load()
        let editor = NoteEditorController(line: line)
        try await editor.openNew(present: false)
        let board = NSPasteboard(name: .init("inkpeg-note-paste-" + UUID().uuidString))
        defer { board.releaseGlobally(); editor.window?.close() }
        board.setString("粘贴标题\n完整中文正文", forType: .string)
        XCTAssertTrue(editor.textView.readSelection(from: board, type: .string))
        try await editor.flushAutosave(); try await editor.dismiss()
        let resumed = NoteEditorController(line: line)
        try await resumed.openNew(present: false)
        defer { resumed.window?.close() }
        XCTAssertEqual(resumed.textView.string, "粘贴标题\n完整中文正文")
        XCTAssertTrue(line.items.isEmpty, "Pasting a draft must not publish a card")
    }
}

// Only the clipboard source is isolated; AppKit insertion, selection and the
// menu binding are real. Live first-responder routing has separate GUI evidence.
// The user's general pasteboard is never changed.
private final class NamedPasteTextView: NSTextView {
    private let board: NSPasteboard
    private let storage: NSTextStorage
    init(board: NSPasteboard) {
        self.board = board
        let storage = NSTextStorage(), layout = NSLayoutManager(), container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        self.storage = storage
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        isRichText = false
    }
    required init?(coder: NSCoder) { fatalError("Unavailable") }
    override func paste(_ sender: Any?) { _ = readSelection(from: board, type: .string) }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) { return isEditable && board.availableType(from: [.string]) != nil }
        return super.validateUserInterfaceItem(item)
    }
}

// XCTest has no running application key window. Exercise AppKit's real native
// undo manager and drain one notification cycle, retaining exact model/save
// assertions. Actual nil-target menu shortcuts require Task 16 GUI acceptance.
@MainActor func performNativeTextUndo(_ undo: UndoManager, redo: Bool = false) {
    if redo { undo.redo() } else { undo.undo() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
