import XCTest
@testable import InkpegCore

final class CaptureMonitorTests: XCTestCase {
    @MainActor
    func testOversizeCaptureFailsWithoutReadyCallbackOrSourceMutation() async throws {
        let root = try folder(), incoming = root.appendingPathComponent("oversize.png")
        let data = try ImageAdmissionTests.fixture()
        let monitor = CaptureMonitor(), failure = expectation(description: "Over-budget capture rejected")
        var ready = 0
        try monitor.start(in: root, onReady: { _ in ready += 1 }, onFailed: { _ in failure.fulfill() })
        try data.write(to: incoming)
        await fulfillment(of: [failure], timeout: 7)
        monitor.stop()
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(try Data(contentsOf: incoming), data)
    }
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC")!
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("inkpeg-tests-monitor-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor
    func testPartialWriteRetriedWithoutAdditionalDirectoryEventAndHistoricalExcluded() async throws {
        let root = try folder(), historical = root.appendingPathComponent("historical.png"), incoming = root.appendingPathComponent("incoming.png")
        try png.write(to: historical)
        let monitor = CaptureMonitor(), event = expectation(description: "Complete new image accepted")
        var received = [URL]()
        try monitor.start(in: root, onReady: { url in received.append(url); monitor.acknowledge(url, success: true); event.fulfill() })
        try Data().write(to: incoming)
        try await Task.sleep(nanoseconds: 400_000_000)
        // In-place writes do not create a new directory entry; retry must discover completion.
        let handle = try FileHandle(forWritingTo: incoming)
        try handle.write(contentsOf: png); try handle.close()
        await fulfillment(of: [event], timeout: 3)
        monitor.stop()
        XCTAssertEqual(received, [incoming.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: incoming), png)
        XCTAssertEqual(try Data(contentsOf: historical), png)
    }
    @MainActor
    func testTemporaryRenameArrivesAndStopCancelsQueuedWork() async throws {
        let root = try folder(), hidden = root.appendingPathComponent(".temporary"), incoming = root.appendingPathComponent("renamed.png")
        let monitor = CaptureMonitor(), event = expectation(description: "Renamed capture accepted")
        var count = 0
        try monitor.start(in: root, onReady: { url in count += 1; XCTAssertEqual(url, incoming.standardizedFileURL); event.fulfill() })
        try png.write(to: hidden); try FileManager.default.moveItem(at: hidden, to: incoming)
        await fulfillment(of: [event], timeout: 3)
        monitor.stop()
        try png.write(to: root.appendingPathComponent("after-stop.png"))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(count, 1)
    }
    @MainActor
    func testFolderMoveInvalidatesWithoutFollowingMovedDirectory() async throws {
        let root = try folder(), moved = root.deletingLastPathComponent().appendingPathComponent("inkpeg-tests-moved-" + UUID().uuidString)
        let monitor = CaptureMonitor(), event = expectation(description: "Move pauses intake")
        try monitor.start(in: root, onReady: { _ in XCTFail("Moved folder must not import") }, onInvalidated: { event.fulfill() })
        try FileManager.default.moveItem(at: root, to: moved)
        await fulfillment(of: [event], timeout: 2)
        monitor.stop()
    }
}
