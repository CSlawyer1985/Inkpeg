import XCTest
import AppKit
import ImageIO
import InkpegCore
@testable import Inkpeg

final class MarkupAdapterTests: XCTestCase {
    @MainActor
    func testNSImageAnimationConvertsFrameZeroAndPreservesReturnedRepresentationFrame() async throws {
        let fixture = try await MarkupFixture()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: ImageBudgetFixtures.twoFrameGIF))
        XCTAssertEqual((representation.value(forProperty: .frameCount) as? NSNumber)?.intValue, 2)
        representation.setProperty(.currentFrame, withValue: 1)
        let image = NSImage(size: NSSize(width: 1, height: 1)); image.addRepresentation(representation)
        let markup = Markup(launchEditor: { _ in }, reportFailure: { XCTFail("In-budget animation must be accepted") })
        markup.edit(fixture.session, store: fixture.store) { _ in }
        await markup.receive([image])
        let saved = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: fixture.session.workingURL)))
        let color = try XCTUnwrap(saved.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.01, "PNG conversion must select black frame zero, even when NSImage currently displays white frame one")
        XCTAssertEqual((representation.value(forProperty: .currentFrame) as? NSNumber)?.intValue, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }
    @MainActor
    func testNonImageURLReturnCannotReplaceAnImageDraft() async throws {
        let fixture = try await MarkupFixture()
        let buffer = try XCTUnwrap(CFDataCreateMutable(nil, 0)), consumer = try XCTUnwrap(CGDataConsumer(data: buffer))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let bytes = buffer as Data, source = fixture.source.deletingLastPathComponent().appendingPathComponent("returned.pdf")
        try bytes.write(to: source)
        var callbacks = 0, failures = 0, writes = 0
        let markup = Markup(launchEditor: { _ in }, reportFailure: { failures += 1 }, persistResult: { _, _, _ in writes += 1 })
        markup.edit(fixture.session, store: fixture.store) { _ in callbacks += 1 }
        await markup.receive([source])
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(failures, 1); XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.session.workingURL), fixture.original)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    @MainActor
    func testOversizeURLAndItemProviderReturnNeverReachPersistenceAndKeepDraft() async throws {
        for useProvider in [false, true] {
            let fixture = try await MarkupFixture()
            let bytes = try ImageBudgetFixtures.encoded()
            let returned = fixture.source.deletingLastPathComponent().appendingPathComponent("returned.bin")
            try bytes.write(to: returned)
            var writes = 0, failures = 0, callbacks = 0
            let markup = Markup(launchEditor: { _ in }, reportFailure: { failures += 1 }, persistResult: { _, _, _ in writes += 1 })
            markup.edit(fixture.session, store: fixture.store) { _ in callbacks += 1 }
            if useProvider {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { completion in
                    completion(bytes, nil); return nil
                }
                await markup.receive([provider])
            } else { await markup.receive([returned]) }
            XCTAssertEqual(failures, 1); XCTAssertEqual(writes, 0); XCTAssertEqual(callbacks, 0)
            XCTAssertTrue(markup.canRetrySaving)
            XCTAssertFalse(markup.hasPendingResult)
            XCTAssertEqual(try Data(contentsOf: fixture.session.workingURL), fixture.original)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
            XCTAssertEqual(try Data(contentsOf: returned), bytes)
        }
    }

    @MainActor
    func testNSImageActualPixelsAreCheckedBeforeTIFFOrCGImageConversion() async throws {
        for dimensions in [(8192, 4097), (0, 1), (1, -1)] {
            let fixture = try await MarkupFixture()
            var failures = 0, writes = 0
            let image = ConversionCountingImage(size: NSSize(width: 1, height: 1))
            let representation = NSImageRep()
            representation.pixelsWide = dimensions.0; representation.pixelsHigh = dimensions.1
            image.addRepresentation(representation)
            let markup = Markup(launchEditor: { _ in }, reportFailure: { failures += 1 }, persistResult: { _, _, _ in writes += 1 })
            markup.edit(fixture.session, store: fixture.store) { _ in XCTFail("Rejected image cannot finish the draft") }
            await markup.receive([image])
            XCTAssertEqual(failures, 1); XCTAssertEqual(writes, 0)
            XCTAssertEqual(image.tiffCalls, 0)
            XCTAssertEqual(image.cgImageCalls, 0, "Actual representations must be checked before expensive conversion, irrespective of 1×1 point size")
            XCTAssertEqual(try Data(contentsOf: fixture.session.workingURL), fixture.original)
        }
    }

    @MainActor
    func testMultiFrameItemProviderAndURLKeepReturnedBytesUnchanged() async throws {
        for useProvider in [false, true] {
            let fixture = try await MarkupFixture(), bytes = ImageBudgetFixtures.twoFrameGIF
            let returned = fixture.source.deletingLastPathComponent().appendingPathComponent("returned.gif")
            try bytes.write(to: returned)
            var callbacks = 0
            let markup = Markup(launchEditor: { _ in }, reportFailure: { XCTFail("Valid animation should remain intact") })
            markup.edit(fixture.session, store: fixture.store) { _ in callbacks += 1 }
            if useProvider {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: "com.compuserve.gif", visibility: .all) { completion in
                    completion(bytes, nil); return nil
                }
                await markup.receive([provider])
            } else { await markup.receive([returned]) }
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.session.workingURL), bytes)
            XCTAssertEqual(try Data(contentsOf: returned), bytes)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        }
    }
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

private final class ConversionCountingImage: NSImage, @unchecked Sendable {
    private let calls = ImageConversionCalls()
    var tiffCalls: Int { calls.count(0) }
    var cgImageCalls: Int { calls.count(1) }
    override var tiffRepresentation: Data? { calls.increment(0); return nil }
    override func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?, context referenceContext: NSGraphicsContext?, hints: [NSImageRep.HintKey: Any]?) -> CGImage? {
        calls.increment(1); return nil
    }
}

private final class ImageConversionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0]
    func increment(_ index: Int) { lock.lock(); defer { lock.unlock() }; values[index] += 1 }
    func count(_ index: Int) -> Int { lock.lock(); defer { lock.unlock() }; return values[index] }
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
