import XCTest
import AppKit
import ImageIO
import InkpegCore
@testable import Inkpeg

final class NativeCopyTests: XCTestCase {
    @MainActor
    func testRealNamedPasteboardReceivesPNGWithoutChangingSource() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-app-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("synthetic.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        try png.write(to: source)
        let store = MaterialStore(root: root.appendingPathComponent("owned")), line = Line(store: store)
        let result = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(result.snapshot)
        let id = try XCTUnwrap(result.snapshot.materials.first?.id)
        let board = NSPasteboard(name: .init("InkpegSynthetic-" + UUID().uuidString))
        let actions = MaterialActions(line: line, root: root.appendingPathComponent("owned"), pasteboard: board)
        try await actions.copy(id)
        let copied = try XCTUnwrap(board.data(forType: .png))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(copied as CFData, nil))
        XCTAssertEqual(CGImageSourceGetStatus(image), .statusComplete)
        XCTAssertEqual(line.copiedID, id)
        XCTAssertEqual(try Data(contentsOf: source), png)
        XCTAssertNil(board.string(forType: .fileURL))
    }
    @MainActor
    func testFailedPasteboardWriteCannotShowCopiedFeedback() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-app-tests-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let result = try await store.importMaterial(.text("synthetic", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(result.snapshot)
        let id = try XCTUnwrap(result.snapshot.materials.first?.id)
        let board = NSPasteboard(name: .init("InkpegSynthetic-" + UUID().uuidString))
        let actions = MaterialActions(line: line, root: root, pasteboard: board, write: { _, _ in false })
        do { try await actions.copy(id); XCTFail("Failure cannot report success") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertNil(line.copiedID)
    }
    @MainActor func testDetailCopyLabelsMatchActualTextImagePDFAndFilePasteboardPayloads() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-native-copy-kinds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let image = root.appendingPathComponent("synthetic.png"); try png.write(to: image)
        let pdf = root.appendingPathComponent("synthetic.pdf")
        let pdfData = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdfData))
        var page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &page, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(page); context.endPDFPage(); context.closePDF()
        try (pdfData as Data).write(to: pdf)
        let file = root.appendingPathComponent("synthetic.bin"); try Data([4, 5, 6]).write(to: file)
        let source = SourceRecord(origin: .clipboard, webURL: URL(string: "https://example.invalid/source"), manualTitle: "Synthetic citation", isManuallyRegistered: true)
        for (input, kind) in [(ImportRequest.text("Synthetic text", source), MaterialKind.text), (.file(image, .fileSelection), .image), (.file(pdf, .fileSelection), .pdf), (.file(file, .fileSelection), .file)] {
            let owned = root.appendingPathComponent(UUID().uuidString)
            let store = MaterialStore(root: owned), line = Line(store: store)
            let imported = try await store.importMaterial(input, into: MatterGroup.ungroupedID, visibleCapacity: 3)
            await line.render(imported.snapshot)
            let record = try XCTUnwrap(imported.snapshot.materials.first); XCTAssertEqual(record.kind, kind)
            let original = try await store.payloadURL(of: record.id), before = try Data(contentsOf: original)
            let board = NSPasteboard(name: .init("InkpegKinds-" + UUID().uuidString))
            let detail = MaterialDetailController(line: line, actions: MaterialActions(line: line, root: owned, pasteboard: board), editor: TextEditorController(line: line))
            try await detail.open(record.id, present: false)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(try XCTUnwrap(detail.window?.contentView)).compactMap { $0 as? NSButton }
            let expected: MessageKey = kind == .text ? .copyWithSource : .copy
            let copy = try XCTUnwrap(buttons.first { $0.title == L(expected) })
            XCTAssertEqual(buttons.filter { $0.title == L(.saveDetails) }.count, 1)
            XCTAssertFalse(buttons.contains { $0.title == L(.saveTitle) || $0.title == L(.saveSource) })
            if kind != .text { XCTAssertFalse(buttons.contains { $0.title == L(.copyWithSource) }) }
            XCTAssertTrue(buttons.contains { $0.title == L(kind == .file ? .showInFinder : .openCopy) })
            for locale in ["en", "zh-Hans", "es"] {
                let localizer = Localizer(localeIdentifier: locale)
                XCTAssertEqual(localizer.string(MaterialActions.copyLabel(for: kind)), localizer.string(expected))
                for key in [MessageKey.saveDetails, .detailDiscard, .detailContinue, .detailUnsavedTitle, .detailUnsavedMessage] {
                    XCTAssertNotEqual(localizer.string(key), key.rawValue)
                }
            }
            copy.performClick(nil)
            for _ in 0..<200 where line.copiedID != record.id { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(line.copiedID, record.id)
            switch kind {
            case .text:
                XCTAssertEqual(board.string(forType: .string), "Synthetic text\n\n" + L(.sourceLabel) + " " + (SourceFormatter.describe(source, localizer: appLocalizer) ?? ""))
                XCTAssertNil(board.string(forType: .fileURL))
            case .image:
                XCTAssertNotNil(board.data(forType: .png)); XCTAssertNil(board.string(forType: .string)); XCTAssertNil(board.string(forType: .fileURL))
            case .pdf, .file:
                let copiedURL = try XCTUnwrap(URL(string: try XCTUnwrap(board.string(forType: .fileURL))))
                XCTAssertEqual(try Data(contentsOf: copiedURL), before); XCTAssertNil(board.string(forType: .string)); XCTAssertNil(board.data(forType: .png))
            }
            XCTAssertEqual(try Data(contentsOf: original), before)
            try await detail.dismiss()
        }
    }

}
