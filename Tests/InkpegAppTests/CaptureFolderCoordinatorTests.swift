import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class CaptureFolderCoordinatorTests: XCTestCase {
    @MainActor
    func testSuccessfulRetryClearsCaptureWarning() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-coordinator-" + UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = RetryCopyFiles(), store = MaterialStore(root: root.appendingPathComponent("owned"), files: files)
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let setting = CaptureFolderSetting(bookmark: bookmark, lastKnownPath: folder.path, enabled: true)
        let snapshot = try await store.apply(.setCaptureFolder(setting))
        let coordinator = CaptureFolderCoordinator(store: store)
        defer { coordinator.stop() }
        let failed = expectation(description: "Copy failure is visible"), imported = expectation(description: "User retry commits one image")
        coordinator.onError = { error in XCTFail("Unexpected coordinator error code " + String((error as NSError).code)) }
        coordinator.onStatusChanged = { if coordinator.status == .captureImportFailed { failed.fulfill() } }
        coordinator.onImported = { _, _, _ in imported.fulfill() }
        coordinator.restore(snapshot)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.status, .captureActive)
        let source = folder.appendingPathComponent("new.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        try png.write(to: source)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(coordinator.pendingCount, 1)
        files.allowCopy()
        coordinator.retryPending()
        await fulfillment(of: [imported], timeout: 3)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(coordinator.status, .captureActive)
        XCTAssertFalse(coordinator.hasWarning)
        let committed = try await store.load()
        XCTAssertEqual(committed.materials.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), png)
    }
}

// One deterministic I/O failure, without filling disks or changing permissions.
private final class RetryCopyFiles: FileOperations, @unchecked Sendable {
    private let disk = SystemFileOperations(), lock = NSLock()
    private var failing = true
    func allowCopy() { lock.lock(); failing = false; lock.unlock() }
    func inspect(_ url: URL) throws -> FileInfo { try disk.inspect(url) }
    func read(_ url: URL) throws -> Data { try disk.read(url) }
    func createDirectory(_ url: URL) throws { try disk.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws {
        lock.lock(); let fail = failing; lock.unlock()
        if fail { throw StoreError.unavailableSpace }
        try disk.copy(source, to: destination)
    }
    func move(_ source: URL, to destination: URL) throws { try disk.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws { try disk.writeAtomic(data, to: destination) }
    func availableBytes(at root: URL) throws -> Int64 { try disk.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try disk.list(directory) }
}
