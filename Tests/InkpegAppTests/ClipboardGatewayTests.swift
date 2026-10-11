import AppKit
import ImageIO
import XCTest
import InkpegCore
@testable import Inkpeg

final class ClipboardGatewayTests: XCTestCase {
    @MainActor
    func testOversizeAndTruncatedImagesRejectBothNativeBytesAndFileURLs() throws {
        let board = NSPasteboard(name: .init("InkpegClipboardBudget-" + UUID().uuidString))
        let gateway = SystemClipboardGateway(pasteboard: board)
        for bytes in [try ImageBudgetFixtures.encoded(), Data(try ImageBudgetFixtures.encoded(4096).dropLast(12))] {
            let item = NSPasteboardItem(); item.setData(bytes, forType: .png)
            board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
            XCTAssertThrowsError(try gateway.readSnapshot())
            let source = URL(fileURLWithPath: "/tmp/inkpeg-clipboard-budget-" + UUID().uuidString + ".bin")
            try bytes.write(to: source)
            board.clearContents(); board.setString(source.absoluteString, forType: .fileURL)
            XCTAssertThrowsError(try gateway.readSnapshot())
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        let item = NSPasteboardItem(); item.setData(try ImageBudgetFixtures.encoded(4096), forType: .png)
        board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(try gateway.readSnapshot().requests.count, 1)
    }
    @MainActor
    func testFilePriorityDoesNotReadOversizedAuxiliaryTextItem() throws {
        let board = NSPasteboard(name: .init("InkpegClipboardPriority-" + UUID().uuidString))
        let source = URL(fileURLWithPath: "/tmp/inkpeg-priority-" + UUID().uuidString + ".txt")
        try Data("有效合成文件".utf8).write(to: source)
        let file = NSPasteboardItem(); file.setString(source.absoluteString, forType: .fileURL)
        let text = NSPasteboardItem(); text.setString(String(repeating: "x", count: ClipboardLimits.textBytes + 1), forType: .string)
        XCTAssertTrue(board.writeObjects([file, text]))
        let contents = try SystemClipboardGateway(pasteboard: board).readSnapshot()
        XCTAssertEqual(contents.requests.count, 1)
        guard case .file = contents.requests.first else { return XCTFail("Only preferred files should be read") }
    }
    @MainActor
    func testNamedPasteboardFileImageTextPrecedenceAndSourceProtection() async throws {
        let board = NSPasteboard(name: .init("InkpegClipboardSynthetic-" + UUID().uuidString))
        let root = URL(fileURLWithPath: "/tmp/inkpeg-clipboard-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("合成文件.txt"), bytes = Data("合成文件内容".utf8)
        try bytes.write(to: source)
        let item = NSPasteboardItem()
        item.setString(source.absoluteString, forType: .fileURL)
        item.setString("附带文件名不应挂成文字", forType: .string)
        item.setData(png(), forType: .png)
        XCTAssertTrue(board.writeObjects([item]))
        let gateway = SystemClipboardGateway(pasteboard: board)
        let contents = try gateway.readSnapshot()
        XCTAssertEqual(contents.requests.count, 1)
        guard case .file(let url, let origin) = contents.requests.first else { return XCTFail("File representation must win") }
        XCTAssertEqual(url, source); XCTAssertEqual(origin, .clipboard)
        let store = MaterialStore(root: root.appendingPathComponent("owned"))
        let service = ClipboardImportService(gateway: gateway, store: store)
        try await store.setClipboardEnabled(true)
        await service.start()
        var saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let image = NSPasteboardItem(); image.setData(png(), forType: .png); image.setString("附带文字", forType: .string)
        board.clearContents(); XCTAssertTrue(board.writeObjects([image]))
        await service.poll()
        saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 2); XCTAssertEqual(saved.materials.last?.kind, .image)
        board.clearContents(); XCTAssertTrue(board.setString("新的合成纯文字", forType: .string))
        await service.poll()
        saved = try await store.load()
        XCTAssertEqual(saved.materials.count, 3); XCTAssertEqual(saved.materials.last?.kind, .text)
        XCTAssertNil(saved.materials.last?.source.webURL)
        XCTAssertNil(saved.materials.last?.source.locator)
    }
    @MainActor
    func testOwnImageCopyIsMarkedAndNotReimported() async throws {
        let board = NSPasteboard(name: .init("InkpegClipboardOwn-" + UUID().uuidString))
        let root = URL(fileURLWithPath: "/tmp/inkpeg-clipboard-own-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let imported = try await store.importMaterial(.imageData(png(), SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(imported.snapshot)
        let actions = MaterialActions(line: line, root: root, pasteboard: board)
        try await actions.copy(try XCTUnwrap(imported.snapshot.materials.first?.id))
        let contents = try SystemClipboardGateway(pasteboard: board).readSnapshot()
        XCTAssertTrue(contents.isSelfProduced)
        XCTAssertTrue(contents.requests.isEmpty)
        XCTAssertNotNil(board.data(forType: .png))
    }
    @MainActor
    func testDirectorySymlinkAndRemoteURLAreRejected() throws {
        let board = NSPasteboard(name: .init("InkpegClipboardInvalid-" + UUID().uuidString))
        let root = URL(fileURLWithPath: "/tmp/inkpeg-clipboard-invalid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt"), link = root.appendingPathComponent("link.txt")
        try Data("合成".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let gateway = SystemClipboardGateway(pasteboard: board)
        for url in [root, link, URL(string: "file://remote-host/secret.txt")!] {
            board.clearContents(); XCTAssertTrue(board.setString(url.absoluteString, forType: .fileURL))
            XCTAssertThrowsError(try gateway.readSnapshot())
        }
        board.clearContents(); XCTAssertTrue(board.setString(String(repeating: "a", count: ClipboardLimits.textBytes + 1), forType: .string))
        XCTAssertThrowsError(try gateway.readSnapshot())
    }
    private func png() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC")!
    }
}
