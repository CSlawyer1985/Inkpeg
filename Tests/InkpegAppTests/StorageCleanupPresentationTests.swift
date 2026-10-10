import AppKit
import InkpegCore
import XCTest
@testable import Inkpeg

final class StorageCleanupPresentationTests: XCTestCase {
    @MainActor func testCancelAndStalePreviewPreserveMaterial() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-cleanup-model-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let imported = try await store.importMaterial(.text("保留内容", SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id), payload = try await store.payloadURL(of: id)
        _ = try await store.apply(.takeDown(id))
        let board = NSPasteboard(name: .init("inkpeg-cleanup-model-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: store)
        let model = IntakeSettingsModel(service: service, capture: CaptureFolderCoordinator(store: store), libraryURL: root, store: store)
        await model.previewCleanup(); XCTAssertTrue(model.showCleanup)
        model.cancelCleanup(); await model.confirmCleanup()
        XCTAssertFalse(model.showCleanup); XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        await model.previewCleanup(); _ = try await store.apply(.hang(id))
        await model.confirmCleanup()
        XCTAssertTrue(model.cleanupFailed); XCTAssertEqual(model.cleanupMessage, L(.cleanupChanged))
        XCTAssertFalse(model.showCleanup); XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        let snapshot = try await store.load(); XCTAssertEqual(snapshot.materials.first?.status, .hanging)
    }

    @MainActor func testPrivacyHideCancelsPreviewAndRejectsCleanup() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-cleanup-privacy-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let imported = try await store.importMaterial(.text("私密内容", SourceRecord(origin: .note)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let id = try XCTUnwrap(imported.snapshot.materials.first?.id), payload = try await store.payloadURL(of: id)
        _ = try await store.apply(.takeDown(id))
        let board = NSPasteboard(name: .init("inkpeg-cleanup-privacy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: store)
        var allowed = true
        let model = IntakeSettingsModel(service: service, capture: CaptureFolderCoordinator(store: store), libraryURL: root, store: store, canClean: { allowed })
        await model.previewCleanup(); XCTAssertTrue(model.showCleanup)
        allowed = false; model.hideCleanup(); await model.confirmCleanup()
        XCTAssertNil(model.cleanupPlan); XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        await model.previewCleanup(); XCTAssertTrue(model.cleanupFailed); XCTAssertFalse(model.showCleanup)
    }
}
