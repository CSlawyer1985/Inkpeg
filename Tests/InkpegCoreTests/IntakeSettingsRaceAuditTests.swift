import XCTest
@testable import InkpegCore

final class IntakeSettingsRaceAuditTests: XCTestCase {
    @MainActor
    func testMenuResumeDuringSettingsSaveMustKeepChosenTypes() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-intake-settings-race-" + UUID().uuidString, isDirectory: true)
        let files = AuditPreferenceWriteGate(), store = MaterialStore(root: root, files: files)
        try await store.setClipboardPreferences(ClipboardPreference(enabled: true, includeExisting: false))
        let board = AuditPreferenceBoard(), service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        var chosen = service.preferences; chosen.files = false
        files.arm()
        let save = Task { await service.updatePreferences(chosen) }
        let started = await Task.detached { files.waitForWrite() }.value
        XCTAssertTrue(started)
        XCTAssertTrue(service.isSavingPreferences)
        await service.setEnabled(true)
        files.releaseWrite()
        let saved = await save.value
        XCTAssertTrue(saved)
        let persisted = try await store.clipboardPreferences()
        XCTAssertFalse(service.preferences.files, "The menu action must retain the user's latest selected types")
        XCTAssertFalse(persisted.files, "The persisted preferences must retain the user's latest selected types")
    }
}

@MainActor private final class AuditPreferenceBoard: ClipboardGateway {
    var onChangeCount: () -> Void = {}
    var changeCount: Int { onChangeCount(); return 1 }
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 1, requests: []) }
}

private final class AuditPreferenceWriteGate: FileOperations, @unchecked Sendable {
    private let base = SystemFileOperations(), lock = NSLock()
    private var armed = false
    private let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func waitForWrite() -> Bool { entered.wait(timeout: .now() + 2) == .success }
    func releaseWrite() { released.signal() }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws {
        lock.lock()
        let block = armed && destination.lastPathComponent == "clipboard-settings.json"
        if block { armed = false }
        lock.unlock()
        if block {
            entered.signal()
            guard released.wait(timeout: .now() + 3) == .success else { throw StoreError.operationInProgress }
        }
        try base.writeAtomic(data, to: destination)
    }
    func availableBytes(at root: URL) throws -> Int64 { try base.availableBytes(at: root) }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
}
