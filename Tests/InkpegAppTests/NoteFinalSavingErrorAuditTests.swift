import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class NoteFinalSavingErrorAuditTests: XCTestCase {
    @MainActor func testHangShortcutStillReportsRealSaveFailureAndCanRetry() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-note-final-error-" + UUID().uuidString)
        let files = NoteFinalSavingFaultFiles(), store = MaterialStore(root: root, files: files)
        let line = Line(store: store); try await line.load()
        let editor = NoteEditorController(line: line)
        try await editor.openNew(present: false)
        defer { editor.window?.close() }
        let id = try XCTUnwrap(editor.draft?.materialID), body = "真实保存失败仍应提示并保留合成正文"
        files.failing = true
        editor.textView.string = body; editor.textDidChange(Notification(name: NSText.didChangeNotification))
        var errors = [StoreError](), completions = 0
        editor.onError = { if let error = $0 as? StoreError { errors.append(error) } }
        editor.onHung = { completions += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.textView.keyDown(with: event)
        for _ in 0..<500 {
            if !errors.isEmpty && !editor.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(errors, [.unavailableSpace])
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(editor.hasUnsavedInput)
        XCTAssertEqual(editor.textView.string, body)
        XCTAssertEqual(editor.draft?.materialID, id)
        XCTAssertTrue(editor.textView.isEditable)
        let before = try await store.load(); XCTAssertTrue(before.materials.isEmpty)
        files.failing = false
        editor.textView.keyDown(with: event)
        for _ in 0..<500 {
            if completions == 1 && !editor.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(errors, [.unavailableSpace])
        XCTAssertEqual(line.snapshot.materials.first?.id, id)
        let payload = try await store.payloadURL(of: id)
        XCTAssertEqual(try String(contentsOf: payload), body)
    }
}

private final class NoteFinalSavingFaultFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); defer { lock.unlock() }; fail = newValue }
    }
    private let base = SystemFileOperations()
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if failing && url.lastPathComponent == "note.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
