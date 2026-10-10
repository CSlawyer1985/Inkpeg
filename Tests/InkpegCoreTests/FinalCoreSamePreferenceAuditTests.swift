import Foundation
import XCTest
@testable import InkpegCore

final class FinalCoreSamePreferenceAuditTests: XCTestCase {
    @MainActor func testSamePreferenceResaveBaselineSurvivesOlderBusyPollCatch() async throws {
        let f = try StoreFixture()
        let files = SamePreferenceFingerprintFault(source: f.source)
        let store = f.makeStore(files: files)
        let preference = ClipboardPreference(enabled: true, includeExisting: false)
        try await store.setClipboardPreferences(preference)
        let board = SamePreferenceClipboardBoard()
        let service = ClipboardImportService(gateway: board, store: store)
        await service.start()
        XCTAssertEqual(board.reads, 0)
        board.changeCount += 1
        board.requests = (0..<ClipboardLimits.items).map { _ in .file(f.source, .clipboard) }
        board.onRead = {
            // Each fingerprint is an actual actor await boundary. Complete a
            // same-value preference update before a later fingerprint fails busy.
            Task {
                let saved = await service.updatePreferences(preference)
                XCTAssertTrue(saved)
                files.markPreferenceSaved()
            }
        }
        await service.poll()
        XCTAssertTrue(files.didRejectAfterPreferenceSave, "The busy error must happen after the same-value settings update finished")
        XCTAssertEqual(service.state, .active, "A stale busy catch must retain the latest successful settings state")
        await service.poll()
        XCTAssertEqual(board.reads, 1, "An older catch must not discard the newer same-value settings baseline")
        XCTAssertEqual(service.state, .active)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.materials.count, 0)
    }
}

@MainActor private final class SamePreferenceClipboardBoard: ClipboardGateway {
    var changeCount = 17
    var reads = 0
    var requests: [ImportRequest] = []
    var onRead: (() -> Void)?
    func readSnapshot() throws -> ClipboardContents {
        reads += 1
        let callback = onRead; onRead = nil; callback?()
        return ClipboardContents(revision: changeCount, requests: requests)
    }
}

private final class SamePreferenceFingerprintFault: FileOperations, @unchecked Sendable {
    let base = SystemFileOperations()
    private let source: URL
    private let lock = NSLock()
    private var preferenceSaved = false, rejected = false
    init(source: URL) { self.source = source }
    func markPreferenceSaved() { lock.lock(); preferenceSaved = true; lock.unlock() }
    var didRejectAfterPreferenceSave: Bool { lock.lock(); defer { lock.unlock() }; return preferenceSaved && rejected }
    func inspect(_ url: URL) throws -> FileInfo {
        lock.lock()
        let reject = url == source && preferenceSaved && !rejected
        if reject { rejected = true }
        lock.unlock()
        if reject { throw StoreError.operationInProgress }
        return try base.inspect(url)
    }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { try base.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func writeAtomic(_ data: Data, to destination: URL) throws { try base.writeAtomic(data, to: destination) }
    func availableBytes(at root: URL) throws -> Int64 { 1_000_000 }
    func trash(_ url: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ url: URL) throws -> [URL] { try base.list(url) }
}
