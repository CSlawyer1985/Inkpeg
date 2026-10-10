import XCTest
@testable import InkpegCore

final class CaptureSettingsTests: XCTestCase {
    func testExplicitSelectionPersistsWithoutImportingOrMovingMaterials() async throws {
        let f = try StoreFixture()
        let store = f.makeStore()
        let setting = CaptureFolderSetting(bookmark: Data([1,2,3]), lastKnownPath: f.source.deletingLastPathComponent().path, enabled: true)
        let selected = try await store.apply(.setCaptureFolder(setting))
        XCTAssertEqual(selected.captureFolder, setting)
        XCTAssertTrue(selected.materials.isEmpty)
        let restarted = try await f.makeStore().load()
        XCTAssertEqual(restarted, selected)
        XCTAssertEqual(try Data(contentsOf: f.source), f.bytes)
    }
    func testDisableKeepsSelection() async throws {
        let f = try StoreFixture()
        let store = f.makeStore()
        var setting = CaptureFolderSetting(bookmark: Data([1,2,3]), lastKnownPath: f.source.deletingLastPathComponent().path, enabled: true)
        _ = try await store.apply(.setCaptureFolder(setting))
        setting.enabled = false
        let paused = try await store.apply(.setCaptureFolder(setting))
        XCTAssertEqual(paused.captureFolder, setting)
    }
}
