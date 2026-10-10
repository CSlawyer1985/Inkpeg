import XCTest
import InkpegCore
@testable import Inkpeg

final class ClipboardPresentationTests: XCTestCase {
    @MainActor
    func testTextCardShowsBoundedExcerptFromOwnedOriginal() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-clipboard-card-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let text = "合成剪贴板文字，卡片需要可辨认。\n" + String(repeating: "正文", count: 5000)
        let result = try await store.importMaterial(.text(text, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        await line.render(result.snapshot)
        let item = try XCTUnwrap(line.items.first)
        let preview = try XCTUnwrap(item.previewText)
        XCTAssertTrue(preview.hasPrefix("合成剪贴板文字"))
        XCTAssertLessThanOrEqual(preview.utf8.count, 4100)
        XCTAssertFalse(item.displayTitle.isEmpty)
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), text, "Display truncation must not edit the saved text")
    }
}
