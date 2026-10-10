import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class IntakeSaveCompletionAuditTests: XCTestCase {
    @MainActor
    func testEarlierSaveMustNotClearLaterSaveFailureWhileItsImportFinishes() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-intake-save-completion-" + UUID().uuidString)
        let files = CompletionAuditFiles(), store = MaterialStore(root: root, files: files)
        let service = ClipboardImportService(gateway: CompletionAuditBoard(), store: store)
        await service.start()
        let model = IntakeSettingsModel(service: service, capture: CaptureFolderCoordinator(store: store))
        service.onStateChanged = { model.refresh() }
        let firstImportReached = expectation(description: "First saved setting waits for import presentation")
        var releaseFirst: CheckedContinuation<Void, Never>?
        service.onSnapshot = { _ in
            firstImportReached.fulfill()
            await withCheckedContinuation { releaseFirst = $0 }
        }
        var first = service.preferences; first.enabled = true
        let firstSave = Task { await model.save(first) }
        await fulfillment(of: [firstImportReached], timeout: 2)
        XCTAssertFalse(model.saving, "Current production refresh exposes enabled controls while the old save call awaits poll")
        files.failPreferenceWrites()
        var second = service.preferences; second.files = false
        await model.save(second)
        XCTAssertTrue(model.failed, "The newer save failed and should remain visible")
        releaseFirst?.resume()
        await firstSave.value
        XCTAssertTrue(model.failed, "An earlier successful save must not hide a later failed save")
    }
}

@MainActor private final class CompletionAuditBoard: ClipboardGateway {
    var changeCount = 1
    func readSnapshot() throws -> ClipboardContents {
        ClipboardContents(revision: 1, requests: [.text("synthetic initial clipboard", SourceRecord(origin: .clipboard))])
    }
}

private final class CompletionAuditFiles: FileOperations, @unchecked Sendable {
    private let base = SystemFileOperations(), lock = NSLock()
    private var failing = false
    func failPreferenceWrites() { lock.lock(); failing = true; lock.unlock() }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws {
        lock.lock(); let fail = failing; lock.unlock()
        if fail && destination.lastPathComponent == "clipboard-settings.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: destination)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
