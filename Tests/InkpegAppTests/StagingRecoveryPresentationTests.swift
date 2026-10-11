import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class StagingRecoveryPresentationTests: XCTestCase {
    @MainActor func testSelectedPreviewCountsMatchActualTransactionBytesAndExportIsRetained() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-staging-model-" + UUID().uuidString)
        let files = PresentationStagingFiles(), store = MaterialStore(root: root, files: files)
        _ = try await store.load()
        for text in ["one", "second"] { try Data(text.utf8).write(to: root.appendingPathComponent("Transactions/" + UUID().uuidString + ".stage")) }
        let service = ClipboardImportService(gateway: EmptyStagingClipboard(), store: store)
        let model = IntakeSettingsModel(service: service, capture: CaptureFolderCoordinator(store: store), libraryURL: root, store: store)
        await model.refreshUsage(); let before = try XCTUnwrap(model.usage?["Transactions"])
        await model.previewCleanup()
        let plan = try XCTUnwrap(model.cleanupPlan), target = try XCTUnwrap(plan.targets.first)
        XCTAssertTrue(model.showCleanup); XCTAssertEqual(plan.stagingCount, 2); XCTAssertEqual(plan.byteCount, before)
        model.selectedCleanupPaths = [target.relativePath]
        let selected = try XCTUnwrap(model.selectedCleanupPlan)
        XCTAssertEqual(selected.stagingCount, 1); XCTAssertEqual(selected.byteCount, target.byteCount)
        let output = root.deletingLastPathComponent().appendingPathComponent("retained-" + UUID().uuidString + ".txt")
        await model.exportStaging(target, to: output)
        XCTAssertFalse(model.cleanupFailed); XCTAssertEqual(model.cleanupMessage, L(.stagingExportDone))
        let retained = try Data(contentsOf: output)
        await model.confirmCleanup()
        XCTAssertFalse(model.cleanupFailed); XCTAssertFalse(model.showCleanup)
        XCTAssertEqual(model.cleanupMessage, String(format: L(.cleanupDone), 1, IntakeSettingsModel.size(target.byteCount)))
        XCTAssertEqual(before - (try XCTUnwrap(model.usage?["Transactions"])), target.byteCount)
        XCTAssertEqual(try Data(contentsOf: output), retained)
        XCTAssertEqual(files.trashCalls, 1)
    }

    @MainActor func testInspectionOnlyInventoryIsVisibleAndCannotBeConfirmed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-staging-inspection-" + UUID().uuidString)
        let files = PresentationStagingFiles(), store = MaterialStore(root: root, files: files)
        _ = try await store.load()
        let unknown = root.appendingPathComponent("Transactions/unknown.stage")
        try Data("inspect me".utf8).write(to: unknown)
        let model = IntakeSettingsModel(service: ClipboardImportService(gateway: EmptyStagingClipboard(), store: store), capture: CaptureFolderCoordinator(store: store), libraryURL: root, store: store)
        await model.previewCleanup()
        XCTAssertTrue(model.showCleanup); XCTAssertEqual(model.cleanupPlan?.stagingInventory.count, 1)
        XCTAssertTrue(model.selectedCleanupPlan?.targets.isEmpty == true)
        await model.confirmCleanup()
        XCTAssertEqual(files.trashCalls, 0); XCTAssertEqual(try Data(contentsOf: unknown), Data("inspect me".utf8))
    }
}

@MainActor private struct EmptyStagingClipboard: ClipboardGateway {
    var changeCount: Int { 0 }
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 0, requests: []) }
}
private final class PresentationStagingFiles: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    var trashCalls = 0
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws { try base.writeAtomic(data, to: destination) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
    func trash(_ source: URL) throws -> URL {
        let folder = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("simulated-trash")
        try base.createDirectory(folder)
        let destination = folder.appendingPathComponent(UUID().uuidString)
        try base.move(source, to: destination); trashCalls += 1; return destination
    }
}
