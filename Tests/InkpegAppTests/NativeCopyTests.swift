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
}
