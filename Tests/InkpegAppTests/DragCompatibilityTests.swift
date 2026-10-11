import AppKit
import XCTest
import InkpegCore
import CryptoKit
import ImageIO
@testable import Inkpeg

final class DragCompatibilityTests: XCTestCase {
    @MainActor
    func testTextDragOffersNativeTextToInputFields() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-drag-test-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let result = try await store.importMaterial(.text("拖入输入框\n第二行", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        let adapter = CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "txt", canExport: { true })
        let provider = try await adapter.prepareProvider(exportRoot: root)
        let board = NSPasteboard(name: .init("InkpegDragTest-" + UUID().uuidString))
        XCTAssertTrue(board.writeObjects([provider]))
        XCTAssertTrue(provider.writableTypes(for: board).contains(.string))
        XCTAssertEqual(board.string(forType: .string), "拖入输入框\n第二行")
        XCTAssertNil(board.string(forType: .fileURL), "Text fields must not see a competing TXT attachment URL")
        let field = NSTextView(); field.isRichText = false
        XCTAssertTrue(field.readSelection(from: board, type: .string))
        XCTAssertEqual(field.string, "拖入输入框\n第二行")
    }
}

extension DragCompatibilityTests {
    @MainActor
    func testRepresentativeImageImportPreviewAndNativeExportRepresentations() async throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/image-representative-1600x1200.png"))
        let root = URL(fileURLWithPath: "/tmp/inkpeg-representative-image-" + UUID().uuidString), store = MaterialStore(root: root)
        let saved = try await store.importMaterial(.imageData(bytes, SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(saved.snapshot.materials.first)
        let payload = try await store.payloadURL(of: record.id)
        XCTAssertNotNil(makeThumbnail(payload))
        let provider = try await CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "png", canExport: { true }).prepareProvider(exportRoot: root)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let data = try XCTUnwrap(provider.pasteboardPropertyList(forType: type) as? Data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1600); XCTAssertEqual(image.height, 1200)
        }
        let raw = try XCTUnwrap(URL(string: XCTUnwrap(provider.pasteboardPropertyList(forType: .fileURL) as? String)))
        XCTAssertEqual(try Data(contentsOf: raw), bytes)
        XCTAssertEqual(try Data(contentsOf: payload), bytes)
    }

    @MainActor
    func testLegacyOversizeImageCanExportRawButCannotPreviewCopyConvertOrMarkup() async throws {
        let fixture = try await ImageBudgetFixtures.legacyStore()
        let line = Line(store: fixture.store); await line.render(fixture.snapshot)
        let board = NSPasteboard(name: .init("InkpegLegacyImage-" + UUID().uuidString))
        board.setString("retain clipboard", forType: .string)
        let actions = MaterialActions(line: line, root: fixture.root, pasteboard: board)
        XCTAssertNil(makeThumbnail(fixture.payload))
        do { try await actions.copy(fixture.record.id); XCTFail("Must reject pixel conversion") }
        catch { XCTAssertEqual(error as? ImageAdmissionError, .pixelBudgetExceeded) }
        XCTAssertEqual(board.string(forType: .string), "retain clipboard")
        do { _ = try await actions.dragProvider(XCTUnwrap(line.items.first)); XCTFail("Must reject PNG/TIFF conversion") }
        catch { XCTAssertEqual(error as? ImageAdmissionError, .pixelBudgetExceeded) }
        do { try await actions.markup(fixture.record.id); XCTFail("Must reject editor decode") }
        catch { XCTAssertEqual(error as? ImageAdmissionError, .pixelBudgetExceeded) }
        let raw = try await fixture.store.exportCopy(of: fixture.record.id, to: fixture.root.deletingLastPathComponent().appendingPathComponent("legacy-export-" + UUID().uuidString + ".png"))
        XCTAssertEqual(try Data(contentsOf: raw), fixture.bytes)
        let adapter = CopyOutProvider(store: fixture.store, id: fixture.record.id, versionID: fixture.record.activeVersionID, suffix: "png", canExport: { true })
        let provider = adapter.provider()
        let promised = fixture.root.deletingLastPathComponent().appendingPathComponent("legacy-promise-" + UUID().uuidString + ".png")
        let failure: Error? = await withCheckedContinuation { continuation in
            adapter.filePromiseProvider(provider, writePromiseTo: promised) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: promised), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.payload), fixture.bytes)
        let unchanged = try await fixture.store.load(); XCTAssertEqual(unchanged, fixture.snapshot)
    }

    @MainActor
    func testAnimatedSourceExportsAllFramesAndConvertsOnlyFirstFrame() async throws {
        let bytes = ImageBudgetFixtures.twoFrameGIF
        let root = URL(fileURLWithPath: "/tmp/inkpeg-animated-drag-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let saved = try await store.importMaterial(.imageData(bytes, SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(saved.snapshot.materials.first)
        let provider = try await CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "gif", canExport: { true }).prepareProvider(exportRoot: root)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let data = try XCTUnwrap(provider.pasteboardPropertyList(forType: type) as? Data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 1)
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, 0, accuracy: 0.01, "PNG and TIFF must both encode black frame zero rather than white frame one")
        }
        let raw = try XCTUnwrap(URL(string: XCTUnwrap(provider.pasteboardPropertyList(forType: .fileURL) as? String)))
        XCTAssertEqual(try Data(contentsOf: raw), bytes)
        let rawSource = try XCTUnwrap(CGImageSourceCreateWithURL(raw as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(rawSource), 2)
    }
    @MainActor
    func testPNGAndReadableFileCopyShareOneDraggingItem() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-drag-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let source = root.appendingPathComponent("original.png"); try png.write(to: source)
        let owned = root.appendingPathComponent("owned"), store = MaterialStore(root: owned)
        let result = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let line = Line(store: store); await line.render(result.snapshot)
        let actions = MaterialActions(line: line, root: owned)
        let provider = try await actions.dragProvider(XCTUnwrap(line.items.first))
        let board = NSPasteboard(name: .init("InkpegDragTest-" + UUID().uuidString))
        XCTAssertTrue(board.writeObjects([provider]))
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(board.data(forType: .png))))
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(board.data(forType: .tiff))))
        let exported = try XCTUnwrap(URL(string: XCTUnwrap(board.string(forType: .fileURL))))
        XCTAssertTrue(exported.path.hasPrefix(owned.appendingPathComponent("Exports").path + "/"))
        XCTAssertEqual(exported.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: exported), png)
        XCTAssertEqual(try Data(contentsOf: source), png)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        let finderTypes = CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "png", canExport: { true }).provider().writableTypes(for: board)
        XCTAssertFalse(finderTypes.isEmpty)
        XCTAssertTrue(Set(finderTypes).isSubset(of: Set(provider.writableTypes(for: board))))
        let destination = root.appendingPathComponent("finder-copy.png")
        let delegate = try XCTUnwrap(provider.delegate)
        let failure: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: destination), png)
        let unchanged = try await store.load(); XCTAssertEqual(unchanged, result.snapshot)
    }

    @MainActor
    func testFileURLIsReadyAndNeverPointsAtOriginalOrManagedPayload() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-drag-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sample.bin"), data = Data([0, 42, 255, 4]); try data.write(to: source)
        let owned = root.appendingPathComponent("owned"), store = MaterialStore(root: owned), line = Line(store: store)
        let result = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        await line.render(result.snapshot)
        let provider = try await MaterialActions(line: line, root: owned).dragProvider(XCTUnwrap(line.items.first))
        let board = NSPasteboard(name: .init("InkpegDragTest-" + UUID().uuidString))
        XCTAssertTrue(board.writeObjects([provider]))
        let exported = try XCTUnwrap(URL(string: XCTUnwrap(board.string(forType: .fileURL))))
        XCTAssertTrue(exported.path.hasPrefix(owned.appendingPathComponent("Exports").path + "/"))
        XCTAssertNotEqual(exported, source); XCTAssertNotEqual(exported, line.items.first?.url)
        XCTAssertEqual(exported.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: exported), data)
        XCTAssertNil(board.string(forType: .string))
        let unchanged = try await store.load(); XCTAssertEqual(unchanged, result.snapshot)
    }

    @MainActor
    func testProviderUsesRenderedVersionAndRejectsPrivacyBeforePublication() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-drag-test-" + UUID().uuidString), store = MaterialStore(root: root), line = Line(store: store)
        let old = try await store.importMaterial(.text("old version", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8).snapshot
        await line.render(old)
        let record = try XCTUnwrap(old.materials.first)
        let edit = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try await store.writeEditingResult(edit, data: Data("new version".utf8))
        let latest = try await store.finishEditing(edit, result: .save(edit.workingURL))
        let renderedItem = try XCTUnwrap(line.items.first)
        let provider = try await MaterialActions(line: line, root: root).dragProvider(renderedItem)
        let board = NSPasteboard(name: .init("InkpegDragTest-" + UUID().uuidString))
        XCTAssertEqual(provider.pasteboardPropertyList(forType: .string) as? String, "old version")
        var hidden = old; hidden.privacyHidden = true; await line.render(hidden)
        XCTAssertTrue(provider.writableTypes(for: board).isEmpty)
        XCTAssertNil(provider.pasteboardPropertyList(forType: .string))
        do { _ = try await MaterialActions(line: line, root: root).dragProvider(renderedItem); XCTFail("Hidden cards cannot start a drag") }
        catch { XCTAssertEqual(error as? StoreError, .invalidSource) }
        let unchanged = try await store.load(); XCTAssertEqual(unchanged, latest)
    }
}

enum ImageBudgetFixtures {
    static func encoded(_ height: Int = 4097) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/image-budget-8192x\(height).png"))
    }
    static var twoFrameGIF: Data {
        let header: [UInt8] = [71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255]
        let black: [UInt8] = [44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0]
        let white: [UInt8] = [44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x4c, 0x01, 0]
        return Data(header + black + white + [0x3b])
    }
    static func legacyStore() async throws -> (root: URL, store: MaterialStore, snapshot: WorkspaceSnapshot, record: MaterialRecord, payload: URL, bytes: Data) {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-legacy-budget-" + UUID().uuidString), bytes = try encoded()
        let id = UUID(), versionID = UUID(), relative = "Materials/" + id.uuidString + "/" + versionID.uuidString + ".png"
        let payload = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: payload)
        let version = MaterialVersion(id: versionID, relativePath: relative, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(bytes.count), kind: .original)
        let record = MaterialRecord(id: id, kind: .image, title: "legacy.png", source: SourceRecord(origin: .drop), versions: [version], originalVersionID: versionID, activeVersionID: versionID)
        var snapshot = WorkspaceSnapshot(); snapshot.materials = [record]
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("state.json"))
        let store = MaterialStore(root: root)
        return (root, store, try await store.load(), record, payload, bytes)
    }
}

extension DragCompatibilityTests {
    @MainActor
    func testImportedTextFormatsOfferCompleteTextAndSafeNamedFinderPromise() async throws {
        for suffix in ["md", "csv", "json", "log"] {
            let root = URL(fileURLWithPath: "/tmp/inkpeg-text-drag-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("original." + suffix), text = "完整第一行\n  second,line\n{\"key\": \"value\"}\n"
            try Data(text.utf8).write(to: source)
            let owned = root.appendingPathComponent("owned"), store = MaterialStore(root: owned), line = Line(store: store)
            let imported = try await store.importMaterial(.file(source, .drop), into: MatterGroup.ungroupedID, visibleCapacity: 8)
            await line.render(imported.snapshot)
            let provider = try await MaterialActions(line: line, root: owned).dragProvider(XCTUnwrap(line.items.first))
            let board = NSPasteboard(name: .init("InkpegTextFormatDrag-" + UUID().uuidString))
            XCTAssertTrue(board.writeObjects([provider]))
            XCTAssertEqual(board.pasteboardItems?.count, 1)
            XCTAssertEqual(board.string(forType: .string), text)
            XCTAssertNil(board.string(forType: .fileURL))
            let field = NSTextView(); field.isRichText = false
            XCTAssertTrue(field.readSelection(from: board, type: .string)); XCTAssertEqual(field.string, text)
            let delegate = try XCTUnwrap(provider.delegate)
            XCTAssertEqual(delegate.filePromiseProvider(provider, fileNameForType: provider.fileType), source.lastPathComponent)
            let firstCopies = try FileManager.default.contentsOfDirectory(at: owned.appendingPathComponent("Exports"), includingPropertiesForKeys: nil)
            let firstFolder = try XCTUnwrap(firstCopies.first)
            let firstFiles = try FileManager.default.contentsOfDirectory(at: firstFolder, includingPropertiesForKeys: nil)
            let firstCopy = try XCTUnwrap(firstFiles.first)
            XCTAssertEqual(firstCopy.lastPathComponent, source.lastPathComponent)
            XCTAssertEqual(try String(contentsOf: firstCopy, encoding: .utf8), text)
            _ = try await MaterialActions(line: line, root: owned).dragProvider(XCTUnwrap(line.items.first))
            let nextCopies = try FileManager.default.contentsOfDirectory(at: owned.appendingPathComponent("Exports"), includingPropertiesForKeys: nil)
            XCTAssertEqual(nextCopies.count, 2, "Repeated source names use independent export directories")
            try await MaterialActions(line: line, root: owned, pasteboard: board).copy(XCTUnwrap(line.items.first).id)
            XCTAssertEqual(board.string(forType: .string), text)
            XCTAssertNil(board.string(forType: .fileURL))
        }
    }
}
