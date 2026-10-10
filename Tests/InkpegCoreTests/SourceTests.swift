import XCTest
@testable import InkpegCore

final class SourceTests: XCTestCase {
    private let zh = Localizer(localeIdentifier: "zh-Hans")
    func testUnknownPageStaysNil() {
        let source = SourceRecord(origin: .clipboard)
        XCTAssertNil(source.locator)
        XCTAssertNil(SourceFormatter.describe(source, localizer: zh))
    }
    func testPDFIndexSixRendersPDFPageSeven() {
        let source = SourceRecord(origin: .fileSelection, filePath: "/synthetic/证据.pdf", locator: .pdfIndex(6))
        let description = SourceFormatter.describe(source, localizer: zh)
        XCTAssertTrue(description?.contains("PDF 第 7 页") == true)
        XCTAssertFalse(description?.contains("印刷") == true)
    }
    func testPrintedPageRemainsManualAndURLIsNotGuessed() {
        let source = SourceRecord(origin: .clipboard, webURL: URL(string: "https://example.invalid/doc"), manualTitle: "合成来源", locator: .printedPage("封二"), isManuallyRegistered: true)
        let description = SourceFormatter.describe(source, localizer: zh)
        XCTAssertTrue(description?.contains("封二") == true)
        XCTAssertTrue(description?.contains("手工登记") == true)
        XCTAssertTrue(description?.contains("https://example.invalid/doc") == true)
        XCTAssertFalse(description?.contains("PDF 第") == true)
    }
    func testSourceAndTitlePersistWithoutChangingOriginalVersion() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let imported = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let before = try XCTUnwrap(imported.snapshot.materials.first)
        var source = before.source; source.manualTitle = "手工来源"; source.locator = .printedPage("第十页"); source.isManuallyRegistered = true
        _ = try await store.apply(.setSource(before.id, source))
        _ = try await store.apply(.renameMaterial(before.id, "合成标题"))
        let loaded = try await f.makeStore().load(), record = try XCTUnwrap(loaded.materials.first)
        XCTAssertEqual(record.source, source); XCTAssertEqual(record.title, "合成标题")
        XCTAssertEqual(record.versions, before.versions)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testInvalidSourceDoesNotMutateSnapshot() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let before = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let id = try XCTUnwrap(before.materials.first?.id)
        for source in [SourceRecord(origin: .clipboard, webURL: URL(string: "javascript:synthetic")), SourceRecord(origin: .clipboard, locator: .pdfIndex(-1))] {
            do { _ = try await store.apply(.setSource(id, source)); XCTFail("Unsafe source") } catch {}
        }
        let after = try await store.load(); XCTAssertEqual(after, before)
    }
    func testFailedSourceSaveKeepsOldSourceAndPayload() async throws {
        let f = try StoreFixture(), store = f.makeStore()
        let before = try await store.importMaterial(.file(f.source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let failing = f.makeStore(files: FaultFiles(.snapshotWrite)), id = try XCTUnwrap(before.materials.first?.id)
        do { _ = try await failing.apply(.setSource(id, SourceRecord(origin: .clipboard, manualTitle: "cannot save"))); XCTFail("Must report failure") } catch {}
        let after = try await failing.load(); XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
}
