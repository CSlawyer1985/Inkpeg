import XCTest
import AppKit
import ImageIO
import InkpegCore
@testable import Inkpeg

final class MarkupAdapterTests: XCTestCase {
    @MainActor
    func testRetryDuringEditingDoesNotOpenASecondEditor() async throws {
        let fixture = try await MarkupFixture()
        var launches = 0, callbacks = 0
        let markup = Markup(launchEditor: { _ in launches += 1 }, reportFailure: { XCTFail("No result was returned") })
        markup.edit(fixture.session, store: fixture.store) { _ in callbacks += 1 }
        await markup.retrySaving()
        XCTAssertEqual(launches, 1, "Retry must not start a second editor while the first is active")
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    @MainActor
    func testResultArrivingDuringWriteFinishesOnlyAfterNewestResultIsSaved() async throws {
        let fixture = try await MarkupFixture()
        let firstWrite = expectation(description: "First returned image write is suspended")
        var releaseWrite: CheckedContinuation<Void, Never>?, writes = 0, callbacks = 0
        let markup = Markup(launchEditor: { _ in }, reportFailure: { XCTFail("Returned data must remain retryable") }, persistResult: { session, store, data in
            writes += 1
            if writes == 1 {
                await withCheckedContinuation { releaseWrite = $0; firstWrite.fulfill() }
            }
            try await store.writeEditingResult(session, data: data)
        })
        markup.edit(fixture.session, store: fixture.store) { _ in callbacks += 1 }
        let originalImage = try XCTUnwrap(NSImage(data: fixture.original))
        let first = Task { await markup.receive([originalImage]) }
        await fulfillment(of: [firstWrite], timeout: 3)
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let newerImage = try XCTUnwrap(NSImage(data: gif))
        await markup.receive([newerImage])
        XCTAssertEqual(callbacks, 0, "The older suspended write must not finish a newer pending result")
        releaseWrite?.resume()
        await first.value
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(callbacks, 1)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(fixture.session.workingURL as CFURL, nil))
        let final = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
        XCTAssertEqual(final.width, 1, "The newest returned image must be the final saved draft")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        let unchanged = try await fixture.store.load()
        XCTAssertEqual(unchanged.materials.first?.versions.count, 1)
    }

    @MainActor
    func testWriteFailureKeepsReturnedImageAndCompletionForRetry() async throws {
        let fixture = try await MarkupFixture()
        var failing = true, callbacks = 0, failures = 0, launches = 0
        let markup = Markup(launchEditor: { _ in launches += 1 }, reportFailure: { failures += 1 }, persistResult: { session, store, data in
            if failing { throw StoreError.unavailableSpace }
            try await store.writeEditingResult(session, data: data)
        })
        markup.edit(fixture.session, store: fixture.store) { _ in callbacks += 1 }
        await markup.receive([try XCTUnwrap(NSImage(data: fixture.original))])
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(markup.hasPendingResult)
        failing = false
        await markup.retrySaving()
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertFalse(markup.hasPendingResult)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }
}

private struct MarkupFixture {
    let source: URL, original: Data, store: MaterialStore, session: EditSession
    init() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-markup-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.png")
        original = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        try original.write(to: source)
        store = MaterialStore(root: root.appendingPathComponent("owned"))
        let result = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        session = try await store.createDerivedVersion(of: record.id, kind: .markup)
    }
}
