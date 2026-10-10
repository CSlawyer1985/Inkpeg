import XCTest
@testable import InkpegCore

final class CaptureIntakeTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/synthetic-capture.png")
    func candidate(_ bytes: Int64 = 99, _ mtime: TimeInterval = 0, decodable: Bool = true, tagged: Bool = true) -> CaptureCandidate {
        CaptureCandidate(url: url, byteCount: bytes, modificationDate: Date(timeIntervalSince1970: mtime), decodable: decodable, systemScreenshotMarked: tagged)
    }
    func testHistoricalFilesExcluded() {
        var intake = CaptureIntake(history: [url])
        XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: 1)), .ignore)
    }
    func testPartialImageRetriesThenImportsOnce() {
        var intake = CaptureIntake()
        XCTAssertEqual(intake.observe(candidate(0, decodable: false), now: Date(timeIntervalSince1970: 0)), .wait)
        XCTAssertEqual(intake.observe(candidate(50, 1, decodable: false), now: Date(timeIntervalSince1970: 1)), .wait)
        XCTAssertEqual(intake.observe(candidate(99, 2), now: Date(timeIntervalSince1970: 2)), .wait)
        XCTAssertEqual(intake.observe(candidate(99, 2), now: Date(timeIntervalSince1970: 2.3)), .ready(url))
        XCTAssertEqual(intake.observe(candidate(99, 2), now: Date(timeIntervalSince1970: 2.6)), .ignore)
        intake.acknowledge(url, success: true)
        XCTAssertEqual(intake.observe(candidate(99, 2), now: Date(timeIntervalSince1970: 3)), .ignore)
    }
    func testCoalescedEventsDoNotResetStabilityOrDuplicateDelivery() {
        var intake = CaptureIntake()
        for time in [0.0, 0.05, 0.1, 0.15] { XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: time)), .wait) }
        XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: 0.3)), .ready(url))
        XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: 0.6)), .ignore)
    }
    func testFailedImportIsRetryableAndNotAcknowledged() {
        var intake = CaptureIntake()
        _ = intake.observe(candidate(), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: 0.3)), .ready(url))
        intake.acknowledge(url, success: false)
        XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: 0.4)), .wait)
        XCTAssertEqual(intake.observe(candidate(), now: Date(timeIntervalSince1970: 0.7)), .ready(url))
    }
    func testTimeoutDoesNotPermanentlyExcludeChangedCandidate() {
        var intake = CaptureIntake()
        _ = intake.observe(candidate(99, decodable: false), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(intake.observe(candidate(99, decodable: false), now: Date(timeIntervalSince1970: 5.1)), .failed)
        XCTAssertEqual(intake.observe(candidate(99, 6), now: Date(timeIntervalSince1970: 6)), .wait)
        XCTAssertEqual(intake.observe(candidate(99, 6), now: Date(timeIntervalSince1970: 6.3)), .ready(url))
    }
    func testDesktopRequiresSystemScreenshotMarker() {
        var intake = CaptureIntake(onlyTagged: true)
        XCTAssertEqual(intake.observe(candidate(tagged: false), now: Date(timeIntervalSince1970: 0)), .ignore)
        XCTAssertEqual(intake.observe(candidate(tagged: true), now: Date(timeIntervalSince1970: 0.3)), .wait)
        XCTAssertEqual(intake.observe(candidate(tagged: true), now: Date(timeIntervalSince1970: 0.6)), .ready(url))
    }
}
final class CaptureRaceTests: XCTestCase {
    @MainActor
    func testArrivalBetweenBaselineAndRegistrationIsObserved() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("inkpeg-tests-observation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historical = root.appendingPathComponent("historical.txt")
        try Data("old".utf8).write(to: historical)
        let incoming = root.appendingPathComponent("new.txt")
        let observed = expectation(description: "Post registration scan includes gap arrival")
        let observer = DirectoryObservation()
        var baseline = Set<URL>()
        var fulfilled = false
        try observer.start(in: root, onBaseline: { baseline = Set($0) }, afterBaseline: {
            try Data("new".utf8).write(to: incoming)
        }, onScan: { urls in
            if Set(urls).subtracting(baseline).contains(incoming), !fulfilled { fulfilled = true; observed.fulfill() }
        }, onInvalidated: {})
        await fulfillment(of: [observed], timeout: 2)
        observer.stop()
        XCTAssertTrue(baseline.contains(historical), "baseline: \(baseline.map(\.absoluteString)); expected: \(historical.absoluteString)")
        XCTAssertFalse(baseline.contains(incoming))
    }
    @MainActor
    func testRealDirectoryWriteEventArrivesAfterRegistration() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("inkpeg-tests-event-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let incoming = root.appendingPathComponent("arrival.txt")
        let event = expectation(description: "Real filesystem event observed")
        let observer = DirectoryObservation()
        var fulfilled = false
        try observer.start(in: root, onBaseline: { _ in }, onScan: { urls in
            if urls.contains(incoming), !fulfilled { fulfilled = true; event.fulfill() }
        }, onInvalidated: {})
        try Data("new".utf8).write(to: incoming)
        await fulfillment(of: [event], timeout: 2)
        observer.stop()
    }
}
