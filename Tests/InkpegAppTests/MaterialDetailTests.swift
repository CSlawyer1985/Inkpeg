import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class MaterialDetailTests: XCTestCase {
    @MainActor func testDetailHasUsableSourceFieldsAndPreviewInIndependentWindow() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-detail-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.text("合成中文摘录 \nEnglish text", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot); let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let board = NSPasteboard(name: .init("InkpegDetail-" + UUID().uuidString))
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: board), editor: TextEditorController(line: line))
        try await detail.open(id, present: false)
        let window = try XCTUnwrap(detail.window), content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(window.canBecomeKey); content.layoutSubtreeIfNeeded()
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let disclosure = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sourceDisclosure" })
        disclosure.performClick(nil); content.layoutSubtreeIfNeeded()
        let fields = descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 5)
        for field in fields { XCTAssertGreaterThan(field.frame.width, 150); XCTAssertGreaterThan(field.frame.height, 12) }
        let preview = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(preview.string, "合成中文摘录 \nEnglish text"); XCTAssertFalse(preview.isEditable)
        XCTAssertGreaterThan(preview.enclosingScrollView?.frame.height ?? 0, 100)
        window.close()
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor func testReopeningSameMaterialKeepsLocalInputAndWindow() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-detail-draft-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.text("Synthetic body", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id)
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: TextEditorController(line: line))
        try await detail.open(id, present: false)
        let window = try XCTUnwrap(detail.window)
        let fields = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        fields[0].stringValue = "Unsaved title"; fields[1].stringValue = "Unsaved source"
        try await detail.open(id, present: false)
        XCTAssertTrue(detail.window === window, "Opening the same detail must preserve its active local draft")
        let current = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(current[0].stringValue, "Unsaved title")
        XCTAssertEqual(current[1].stringValue, "Unsaved source")
        detail.window?.close()
    }
    @MainActor func testNontextDetailDoesNotPromiseCopyWithSource() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-detail-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("synthetic.bin"); try Data([1, 2, 3]).write(to: file)
        let store = MaterialStore(root: root.appendingPathComponent("owned")), line = Line(store: store)
        let imported = try await store.importMaterial(.file(file, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: TextEditorController(line: line))
        try await detail.open(try XCTUnwrap(imported.snapshot.materials.first?.id), present: false)
        let buttons = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSButton }
        XCTAssertFalse(buttons.contains { $0.title == L(.copyWithSource) })
        XCTAssertTrue(buttons.contains { $0.title == L(.copy) })
        detail.window?.close()
    }

    @MainActor private func draftFixture(files: any FileOperations = SystemFileOperations()) async throws -> (MaterialStore, Line, MaterialDetailController, [UUID], [NSTextField]) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-detail-transitions-" + UUID().uuidString)
        let store = MaterialStore(root: root, files: files), line = Line(store: store)
        var ids: [UUID] = []
        for text in ["Synthetic A", "Synthetic B"] {
            let imported = try await store.importMaterial(.text(text, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
            await line.render(imported.snapshot); ids.append(try XCTUnwrap(imported.snapshot.materials.last?.id))
        }
        let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: root, pasteboard: NSPasteboard(name: .init(UUID().uuidString))), editor: TextEditorController(line: line))
        try await detail.open(ids[0], present: false)
        let fields = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        return (store, line, detail, ids, fields)
    }
    @MainActor func testContinueEditingCancelsSwitchAndNativeCloseThenDiscardSwitchesWithoutWrite() async throws {
        let (store, _, detail, ids, fields) = try await draftFixture()
        let window = try XCTUnwrap(detail.window)
        fields[0].stringValue = "Draft title"; fields[1].stringValue = "Draft source"
        var choices = 0
        detail.chooseUnsavedChanges = { choices += 1; return .continueEditing }
        try await detail.open(ids[1], present: false)
        XCTAssertTrue(detail.window === window); XCTAssertTrue(detail.hasUnsavedChanges)
        XCTAssertEqual(fields[0].stringValue, "Draft title"); XCTAssertEqual(fields[1].stringValue, "Draft source")
        window.performClose(nil)
        for _ in 0..<100 where choices < 2 { await Task.yield() }
        XCTAssertEqual(choices, 2, "Native close must invoke the same three-way guard")
        XCTAssertTrue(detail.window === window); XCTAssertEqual(fields[1].stringValue, "Draft source")
        detail.chooseUnsavedChanges = { .discard }
        try await detail.open(ids[1], present: false)
        XCTAssertFalse(detail.window === window); XCTAssertFalse(detail.hasUnsavedChanges)
        let saved = try await store.load()
        XCTAssertEqual(saved.materials.first?.title, "Synthetic A"); XCTAssertNil(saved.materials.first?.source.manualTitle)
        try await detail.dismiss(); XCTAssertNil(detail.window)
    }
    @MainActor func testSaveBeforeSwitchAndBeforeClosePersistsBothFields() async throws {
        let (store, _, detail, ids, fields) = try await draftFixture()
        fields[0].stringValue = "Saved title"; fields[1].stringValue = "Saved source"
        detail.chooseUnsavedChanges = { .save }
        try await detail.open(ids[1], present: false)
        var saved = try await store.load()
        XCTAssertEqual(saved.materials.first?.title, "Saved title"); XCTAssertEqual(saved.materials.first?.source.manualTitle, "Saved source")
        let nextFields = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        nextFields[0].stringValue = "Second title"; nextFields[1].stringValue = "Second source"
        try await detail.dismiss(); XCTAssertNil(detail.window)
        saved = try await store.load()
        XCTAssertEqual(saved.materials.last?.title, "Second title"); XCTAssertEqual(saved.materials.last?.source.manualTitle, "Second source")
    }
    @MainActor func testFailedFirstWriteRetainsAllInputAndCannotSwitchOrClose() async throws {
        let files = DetailFaultFiles()
        let (store, _, detail, ids, fields) = try await draftFixture(files: files)
        let window = try XCTUnwrap(detail.window)
        fields[0].stringValue = "Retained title"; fields[1].stringValue = "Retained source"
        files.arm(failAt: 1); detail.chooseUnsavedChanges = { .save }
        do { try await detail.open(ids[1], present: false); XCTFail("Failed save must prevent switch") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertTrue(detail.window === window); XCTAssertTrue(detail.hasUnsavedChanges)
        XCTAssertEqual(fields[0].stringValue, "Retained title"); XCTAssertEqual(fields[1].stringValue, "Retained source")
        files.arm(failAt: 1)
        do { try await detail.dismiss(); XCTFail("Failed save must prevent close") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertTrue(detail.window === window)
        let saved = try await store.load(); XCTAssertEqual(saved.materials.first?.title, "Synthetic A")
        files.arm(failAt: nil); try await detail.save(); XCTAssertFalse(detail.hasUnsavedChanges)
        try await detail.dismiss()
    }
    @MainActor func testSecondWriteFailureRetainsSourceAndRetriesOnlyIncompleteField() async throws {
        let files = DetailFaultFiles()
        let (store, _, detail, _, fields) = try await draftFixture(files: files)
        let window = try XCTUnwrap(detail.window)
        fields[0].stringValue = "Committed title"; fields[1].stringValue = "Pending source"
        files.arm(failAt: 2)
        do { try await detail.save(); XCTFail("Second write must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertEqual(files.writes, 2)
        XCTAssertTrue(detail.window === window); XCTAssertTrue(detail.hasUnsavedChanges)
        XCTAssertTrue(fields.allSatisfy(\.isEditable)); XCTAssertEqual(fields[0].stringValue, "Committed title"); XCTAssertEqual(fields[1].stringValue, "Pending source")
        var saved = try await store.load()
        XCTAssertEqual(saved.materials.first?.title, "Committed title"); XCTAssertNil(saved.materials.first?.source.manualTitle)
        files.arm(failAt: nil); try await detail.save()
        XCTAssertEqual(files.writes, 1, "Retry must write the incomplete source only")
        XCTAssertFalse(detail.hasUnsavedChanges)
        saved = try await store.load(); XCTAssertEqual(saved.materials.first?.source.manualTitle, "Pending source")
        XCTAssertEqual(saved.materials.first?.versions.count, 1)
        try await detail.dismiss()
    }
    @MainActor func testPrivacyConcealsDraftAndPreventsWritesOrPrompt() async throws {
        let (store, line, detail, _, fields) = try await draftFixture()
        fields[0].stringValue = "Private draft"; fields[1].stringValue = "Private source"
        var snapshot = line.snapshot; snapshot.privacyHidden = true; await line.render(snapshot)
        var prompted = false; detail.chooseUnsavedChanges = { prompted = true; return .discard }
        try await detail.dismiss()
        XCTAssertFalse(prompted); XCTAssertNotNil(detail.window); XCTAssertTrue(detail.hasUnsavedChanges)
        XCTAssertTrue(fields.allSatisfy { !$0.isEditable && !$0.isSelectable })
        XCTAssertTrue(detail.window?.contentView?.subviews.first?.isHidden == true)
        do { try await detail.save(); XCTFail("Hidden draft must not save") }
        catch { XCTAssertEqual(error as? StoreError, .invalidSource) }
        let saved = try await store.load(); XCTAssertEqual(saved.materials.first?.title, "Synthetic A")
        snapshot.privacyHidden = false; await line.render(snapshot)
        XCTAssertEqual(fields[0].stringValue, "Private draft"); XCTAssertEqual(fields[1].stringValue, "Private source")
        detail.chooseUnsavedChanges = { .discard }; try await detail.dismiss()
    }

}


private final class DetailFaultFiles: FileOperations, @unchecked Sendable {
    private let base = SystemFileOperations(), lock = NSLock()
    private var failure: Int?, count = 0
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func arm(failAt: Int?) { lock.lock(); defer { lock.unlock() }; failure = failAt; count = 0 }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "state.json" {
            lock.lock(); count += 1; let fail = count == failure; lock.unlock()
            if fail { throw StoreError.unavailableSpace }
        }
        try base.writeAtomic(data, to: url)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
