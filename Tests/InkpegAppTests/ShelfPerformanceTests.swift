import AppKit
import QuartzCore
import Combine
import XCTest
@testable import InkpegCore
@testable import Inkpeg

/// Opt-in local experiment. Ordinary suites run the integrity cases below;
/// the full experiment is selected with INKPEG_PERFORMANCE_OUTPUT. All input
/// bytes and windows are synthetic; no app delegate, capture or clipboard runs.
final class ShelfPerformanceTests: XCTestCase {
    @MainActor func testNativeMixedShelfBenchmark() async throws {
        guard let output = ProcessInfo.processInfo.environment["INKPEG_PERFORMANCE_OUTPUT"] else { return }
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var rows = [[String: Any]]()
        let pilot = ProcessInfo.processInfo.environment["INKPEG_PERFORMANCE_PILOT"] != nil
        // Same fixtures/protocol, bounded Task 13 PDF before/after comparison.
        let visualComparison = ProcessInfo.processInfo.environment["INKPEG_PERFORMANCE_VISUAL"] != nil
        for count in (visualComparison ? [200] : pilot ? [20] : [20, 100, 200, 1000]) {
            for repetition in 1...(visualComparison ? 3 : pilot ? 1 : 5) {
                let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/performance-" + UUID().uuidString)
                let snapshot = try syntheticShelf(count: count, root: root)
                let files = ShelfReadCounter()
                let store = MaterialStore(root: root, files: files)
                var thumbnails = 0, thumbnailMS = 0.0
                let line = Line(store: store, thumbnail: { url in
                    thumbnails += 1
                    let start = CACurrentMediaTime()
                    defer { thumbnailMS += (CACurrentMediaTime() - start) * 1000 }
                    return makeThumbnail(url)
                })
                line.revealed = true; line.resizeViewport(1200)
                let host = LineHostingView(line: line)
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 1200, height: 210)
                if pilot { panel.orderFront(nil) }
                defer { panel.close() }
                let memoryBefore = residentBytes()
                let firstStart = CACurrentMediaTime()
                try await line.load()
                let firstModel = elapsed(firstStart)
                let firstFrame = try await renderFrame(host)
                let firstTotal = (firstFrame.completedAt - firstStart) * 1000
                XCTAssertEqual(line.items.count, count)
                XCTAssertEqual(line.items.map(\.id), snapshot.materials.map(\.id))
                var first: [String: Any] = ["modelWallMS": firstModel, "mainLayoutRasterMS": firstFrame.mainMS, "mainLayoutDisplayMS": firstFrame.layoutMS + firstFrame.displayMS, "readbackMS": firstFrame.readbackMS, "nativeUpdateSubmittedMS": (firstFrame.submittedAt - firstStart) * 1000,
                    "nativeSubmissionResponseMS": firstTotal, "payloadReads": files.payloadReads,
                    "payloadBytes": files.payloadBytes, "thumbnailCalls": thumbnails, "thumbnailMainMS": thumbnailMS]
                // Capture settled evidence independently of first-update timing.
                try await Task.sleep(nanoseconds: 700_000_000)
                let settled = try await renderFrame(host, capture: repetition == 1)
                if repetition == 1 {
                    try settled.png.write(to: outputURL.appendingPathComponent("shelf-\(count)-first.png"))
                }
                first["evidencePNGBytes"] = settled.png.count
                first["evidenceReadbackMS"] = settled.readbackMS
                var increments = [[String: Any]](), scrolls = [[String: Any]](), drags = [[String: Any]]()
                for operation in 0..<1 {
                    let next = try await store.apply(.renameMaterial(snapshot.materials[count - 1].id, "Synthetic update \(operation)"))
                    files.reset(); thumbnails = 0; thumbnailMS = 0
                    let start = CACurrentMediaTime()
                    await line.render(next)
                    let model = elapsed(start)
                    let frame = try await renderFrame(host)
                    increments.append(["modelWallMS": model, "mainLayoutRasterMS": frame.mainMS, "mainLayoutDisplayMS": frame.layoutMS + frame.displayMS, "nativeUpdateSubmittedMS": (frame.submittedAt - start) * 1000,
                        "nativeSubmissionResponseMS": (frame.completedAt - start) * 1000, "payloadReads": files.payloadReads,
                        "payloadBytes": files.payloadBytes, "thumbnailCalls": thumbnails, "thumbnailMainMS": thumbnailMS])
                }
                line.scroll(by: -line.maximumScrollOffset)
                _ = try await renderFrame(host)
                for _ in 0..<3 {
                    files.reset(); thumbnails = 0; thumbnailMS = 0
                    let start = CACurrentMediaTime()
                    line.scroll(by: 150)
                    let model = elapsed(start)
                    let frame = try await renderFrame(host)
                    scrolls.append(["modelMainMS": model, "mainLayoutRasterMS": frame.mainMS, "mainLayoutDisplayMS": frame.layoutMS + frame.displayMS, "nativeUpdateSubmittedMS": (frame.submittedAt - start) * 1000,
                        "mainModelLayoutDisplayMS": model + frame.mainMS, "layoutMS": frame.layoutMS, "displayMS": frame.displayMS, "readbackMS": frame.readbackMS, "nativeSubmissionResponseMS": (frame.completedAt - start) * 1000,
                        "payloadReads": files.payloadReads, "thumbnailCalls": thumbnails])
                }
                if repetition == 1 {
                    let frame = try await renderFrame(host, capture: true)
                    try frame.png.write(to: outputURL.appendingPathComponent("shelf-\(count)-scrolled.png"))
                }
                for record in snapshot.materials.prefix(4) {
                    files.reset()
                    let start = CACurrentMediaTime()
                    let provider = try await CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID,
                        suffix: URL(fileURLWithPath: record.activeVersion!.relativePath).pathExtension,
                        canExport: { !line.snapshot.privacyHidden }).prepareProvider(exportRoot: root)
                    drags.append(["kind": record.kind.rawValue, "prepareWallMS": elapsed(start), "payloadReads": files.payloadReads])
                    XCTAssertNotNil(provider.userInfo)
                }
                rows.append(["count": count, "repeat": repetition, "firstScreen": first,
                    "incremental": increments, "scroll": scrolls, "dragPreparation": drags,
                    "residentBeforeBytes": memoryBefore, "residentAfterBytes": residentBytes()])
                let result: [String: Any] = ["schemaVersion": 1, "system": ProcessInfo.processInfo.operatingSystemVersionString,
                    "processors": ProcessInfo.processInfo.processorCount, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                    "method": "Actual LineHostingView and SwiftUI/AppKit layout/display/CATransaction.flush after main-actor yield. Timed updates end at native submission, not completed onscreen frames; synchronous bitmap readback is separate first-repeat evidence at each size. Main work is model assignment plus explicit layout/display; SwiftUI scheduling/reconciliation during yield is included only in response wall time. No end-to-end display-response pass is inferred. nativeUpdateSubmittedMS stops before bitmap readback and is NOT a completed display-frame guarantee. Bitmap readback adds substantial fixed synchronous overhead (~770ms in pilot), including in a visible non-key synthetic window. No WindowServer display fence; no physical input latency claim. First response excludes animation settlement; evidence PNG waits 700ms. Incremental state rename committed before timing; Line.render plus frame measured. All records created directly as valid synthetic managed fixtures, four equal material kinds; image 1920x1080, text 4KiB, PDF one page, file 128KiB. One process, OS caches warm across repeats, no cache flush. Memory is process resident size, not isolated allocation delta.",
                    "targets": ["warm200ResponseP95MS": 100, "scroll200MainWorkTargetMS": 16], "samples": rows]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL.appendingPathComponent("samples.json"))
                print("SHELF_SAMPLE count=\(count) repeat=\(repetition) first_model_ms=\(firstModel) first_frame_ms=\(firstFrame.mainMS)")
            }
        }
    }

    @MainActor private func renderFrame(_ host: NSView, capture: Bool = false) async throws -> (mainMS: Double, png: Data, completedAt: CFTimeInterval, layoutMS: Double, displayMS: Double, readbackMS: Double, submittedAt: CFTimeInterval) {
        await Task.yield()
        let start = CACurrentMediaTime()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let layoutMS = elapsed(start)
        host.displayIfNeeded()
        CATransaction.flush()
        let displayMS = elapsed(start) - layoutMS
        let readbackStart = CACurrentMediaTime()
        if !capture { return (elapsed(start), Data(), readbackStart, layoutMS, displayMS, 0, readbackStart) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let completedAt = CACurrentMediaTime()
        let mainMS = elapsed(start)
        return (mainMS, try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), completedAt, layoutMS, displayMS, (completedAt - readbackStart) * 1000, readbackStart)
    }
    private func elapsed(_ start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1000 }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    @MainActor private func syntheticShelf(count: Int, root: URL) throws -> WorkspaceSnapshot {
        let files = SystemFileOperations()
        try files.createDirectory(root)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        for index in 0..<150 {
            context.setFillColor(CGColor(red: CGFloat(index % 17) / 20, green: 0.35, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 30 + (index % 5) * 375, y: 20 + (index / 5) * 34, width: 300 - index % 70, height: 18))
        }
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let pdf = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdfContext = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: pdf)), mediaBox: &page, nil))
        pdfContext.beginPDFPage(nil); pdfContext.setFillColor(CGColor(gray: 0.4, alpha: 1))
        pdfContext.fill(CGRect(x: 50, y: 500, width: 450, height: 80)); pdfContext.endPDFPage(); pdfContext.closePDF()
        var snapshot = WorkspaceSnapshot()
        for index in 0..<count {
            let id = UUID(), versionID = UUID()
            let kind: MaterialKind = [.text, .image, .pdf, .file][index % 4]
            let bytes: Data, suffix: String
            switch kind {
            case .text: bytes = Data(("Synthetic material \(index)\n" + String(repeating: "local test note ", count: 270)).utf8); suffix = "txt"
            case .image: bytes = png; suffix = "png"
            case .pdf: bytes = pdf as Data; suffix = "pdf"
            case .file: bytes = Data(repeating: UInt8(index % 255), count: 128 * 1024); suffix = "bin"
            }
            let relative = "Materials/\(id.uuidString)/\(versionID.uuidString).\(suffix)"
            let destination = root.appendingPathComponent(relative)
            try files.createDirectory(destination.deletingLastPathComponent()); try files.writeAtomic(bytes, to: destination)
            let version = MaterialVersion(id: versionID, relativePath: relative, sha256: ContentStore.digest(bytes), byteCount: Int64(bytes.count), kind: .original)
            snapshot.materials.append(MaterialRecord(id: id, kind: kind, order: index, title: "Synthetic \(kind.rawValue) \(index)",
                source: SourceRecord(origin: .drop, manualTitle: "Synthetic source \(index)"), versions: [version], originalVersionID: versionID, activeVersionID: versionID))
        }
        try files.writeAtomic(JSONEncoder().encode(snapshot), to: root.appendingPathComponent("state.json"))
        return snapshot
    }
}

private final class ShelfReadCounter: FileOperations, @unchecked Sendable {
    private let base = SystemFileOperations(), lock = NSLock()
    private var reads = 0, bytes: Int64 = 0
    var beforePayloadRead: (() -> Void)?
    var payloadReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var payloadBytes: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    func reset() { lock.lock(); defer { lock.unlock() }; reads = 0; bytes = 0 }
    func read(_ url: URL) throws -> Data {
        if url.path.contains("/Materials/") { beforePayloadRead?() }
        let data = try base.read(url)
        if url.path.contains("/Materials/") { lock.lock(); reads += 1; bytes += Int64(data.count); lock.unlock() }
        return data
    }
    func inspect(_ u: URL) throws -> FileInfo { try base.inspect(u) }
    func createDirectory(_ u: URL) throws { try base.createDirectory(u) }
    func copy(_ u: URL, to v: URL) throws { try base.copy(u, to: v) }
    func move(_ u: URL, to v: URL) throws { try base.move(u, to: v) }
    func writeAtomic(_ d: Data, to u: URL) throws { try base.writeAtomic(d, to: u) }
    func availableBytes(at u: URL) throws -> Int64 { try base.availableBytes(at: u) }
    func trash(_ u: URL) throws -> URL { try base.trash(u) }
    func list(_ u: URL) throws -> [URL] { try base.list(u) }
}

extension ShelfPerformanceTests {
    @MainActor func testWarmRenderReusesPresentationOnlyAfterFullIntegrityRead() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-regression-" + UUID().uuidString)
        let initial = try syntheticShelf(count: 4, root: root)
        let files = ShelfReadCounter()
        let counted = MaterialStore(root: root, files: files)
        var builds = 0
        let line = Line(store: counted, thumbnail: { url in builds += 1; return makeThumbnail(url) })
        try await line.load()
        let originalThumbs = line.items.map(\.thumb)
        XCTAssertEqual(builds, 4)
        files.reset()
        var renamed = initial
        renamed.materials[3].title = "Updated visible title"
        await line.render(renamed)
        XCTAssertEqual(builds, 4, "An unchanged version should reuse its admitted presentation")
        XCTAssertEqual(files.payloadReads, 4, "Cache hits must still verify full payload digests")
        XCTAssertEqual(line.items.last?.displayTitle, "Updated visible title")
        for index in 0..<4 { XCTAssertTrue(originalThumbs[index] === line.items[index].thumb) }
    }

    @MainActor func testCachedVersionChangesTamperingAndPrivacyDoNotShowStaleContent() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-boundaries-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let initial = try await store.importMaterial(.text("original", SourceRecord(origin: .drop, manualTitle: "source")), into: MatterGroup.ungroupedID, visibleCapacity: Int.max)
        let record = try XCTUnwrap(initial.snapshot.materials.first)
        var builds = 0
        let line = Line(store: store, thumbnail: { url in builds += 1; return makeThumbnail(url) })
        await line.render(initial.snapshot)
        let edit = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
        try await store.writeEditingResult(edit, data: Data("revision".utf8))
        let next = try await store.finishEditing(edit, result: .save(edit.workingURL))
        await line.render(next)
        XCTAssertEqual(line.items.first?.previewText, "revision")
        XCTAssertEqual(line.items.first?.versionID, next.materials.first?.activeVersionID)
        XCTAssertEqual(builds, 2)
        var errors = 0; line.onError = { _ in errors += 1 }
        let url = try await store.payloadURL(of: record.id)
        try Data("tampered".utf8).write(to: url) // Same length, changed digest.
        await line.render(next)
        XCTAssertEqual(errors, 1); XCTAssertTrue(line.items.isEmpty)
        do { _ = try await CopyOutProvider(store: store, id: record.id, versionID: next.materials[0].activeVersionID, suffix: "txt", canExport: { true }).prepareProvider(exportRoot: root); XCTFail("Tampering must reject export") } catch {}
        try Data("revision".utf8).write(to: url)
        await line.render(next)
        XCTAssertEqual(builds, 3, "Damaged entries must have been evicted")
        var hidden = next; hidden.privacyHidden = true
        await line.render(hidden)
        XCTAssertTrue(line.items.isEmpty)
        let shown = next
        await line.render(shown)
        XCTAssertEqual(builds, 4, "Privacy must release cached previews")
        XCTAssertEqual(line.items.first?.previewText, "revision")
        XCTAssertEqual(shown.materials[0].source, record.source)
        XCTAssertEqual(shown.materials[0].originalVersionID, record.originalVersionID)
    }

    @MainActor func testRapidPreparedDragsStayBoundToTheirVersionsAndPrivacy() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-drag-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        let initial = try await store.importMaterial(.text("original", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max)
        let record = try XCTUnwrap(initial.snapshot.materials.first)
        await line.render(initial.snapshot)
        var providers = [ContentFilePromiseProvider]()
        for index in 0..<4 {
            let edit = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
            try await store.writeEditingResult(edit, data: Data("version \(index)".utf8))
            let next = try await store.finishEditing(edit, result: .save(edit.workingURL))
            await line.render(next)
            let card = try XCTUnwrap(line.items.first)
            let provider = try await CopyOutProvider(store: store, id: card.id, versionID: card.versionID, suffix: "txt", canExport: { !line.snapshot.privacyHidden }).prepareProvider(exportRoot: root)
            providers.append(try XCTUnwrap(provider as? ContentFilePromiseProvider))
        }
        for (index, provider) in providers.enumerated() { XCTAssertEqual(provider.pasteboardPropertyList(forType: .string) as? String, "version \(index)") }
        var hidden = line.snapshot; hidden.privacyHidden = true; await line.render(hidden)
        XCTAssertTrue(line.items.isEmpty)
        for provider in providers { XCTAssertNil(provider.pasteboardPropertyList(forType: .string)) }
    }
}

extension ShelfPerformanceTests {
    @MainActor func testLargeShelfRealizesBoundedViewsKeepsOverlapAndBothEndsReachable() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-viewport-" + UUID().uuidString)
        let initial = try syntheticShelf(count: 200, root: root)
        let line = Line(store: MaterialStore(root: root))
        try await line.load(); line.revealed = true; line.resizeViewport(1200)
        let host = LineHostingView(line: line)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        defer { panel.close() }
        var copied: UUID?
        line.onCopy = { copied = $0 }
        func descendants(_ view: NSView) -> [GrabView] { (view as? GrabView).map { [$0] } ?? view.subviews.flatMap(descendants) }
        func identities() -> [UUID: ObjectIdentifier] {
            var result = [UUID: ObjectIdentifier]()
            for view in descendants(host) {
                copied = nil; view.onClick()
                if let id = copied { result[id] = ObjectIdentifier(view) }
            }
            return result
        }
        line.scroll(by: -line.maximumScrollOffset)
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 100_000_000)
        let before = identities()
        XCTAssertLessThanOrEqual(before.count, 16, "Only the viewport and its neighbours should create native views")
        XCTAssertNotNil(before[initial.materials[0].id])
        XCTAssertFalse(line.claimArrival(initial.materials[0].id), "The native view has consumed its first arrival")
        line.scroll(by: 120)
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 100_000_000)
        let after = identities(), overlap = Set(before.keys).intersection(after.keys)
        XCTAssertGreaterThanOrEqual(overlap.count, 4)
        for id in overlap { XCTAssertEqual(before[id], after[id], "Scrolling must retain overlapping card identity") }
        line.scroll(by: line.maximumScrollOffset)
        XCTAssertFalse(line.claimArrival(initial.materials.last!.id), "Manual scrolling must not trigger entry for previously offscreen cards")
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(identities()[initial.materials.last!.id])
        XCTAssertLessThanOrEqual(line.cardX(index: 199, width: 1200) + Layout.cardWidth / 2, 1200)
        XCTAssertEqual(line.items.map(\.id), initial.materials.map(\.id))
        let end = line.scrollOffset
        line.draggingID = initial.materials.last!.id
        line.scroll(by: -1000); XCTAssertEqual(line.scrollOffset, end)
        _ = try await renderFrame(host)
        XCTAssertNotNil(identities()[initial.materials.last!.id])
        line.draggingID = nil; line.pressedID = initial.materials.last!.id
        line.scroll(by: -1000); XCTAssertEqual(line.scrollOffset, end)
        line.pressedID = nil
        line.scroll(by: -line.maximumScrollOffset)
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(identities()[initial.materials[0].id])
        XCTAssertFalse(line.claimArrival(initial.materials[0].id), "Returning to a realized card must not replay arrival")
        let unchanged = try await line.store.load(); XCTAssertEqual(unchanged, initial)
    }
}

extension ShelfPerformanceTests {
    @MainActor func testPrivacyCancelsAnInFlightCachedRender() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-race-" + UUID().uuidString)
        let snapshot = try syntheticShelf(count: 4, root: root)
        let files = ShelfReadCounter()
        let line = Line(store: MaterialStore(root: root, files: files))
        try await line.load()
        let entered = expectation(description: "Payload integrity read entered")
        let gate = DispatchSemaphore(value: 0)
        files.beforePayloadRead = { files.beforePayloadRead = nil; entered.fulfill(); _ = gate.wait(timeout: .now() + 1) }
        let pending = Task { await line.render(snapshot) }
        await fulfillment(of: [entered], timeout: 2)
        var hidden = snapshot; hidden.privacyHidden = true
        await line.render(hidden)
        gate.signal()
        await pending.value
        XCTAssertTrue(line.snapshot.privacyHidden)
        XCTAssertTrue(line.items.isEmpty, "A late validated cache hit must not repopulate a hidden shelf")
        files.beforePayloadRead = nil
    }
}

extension ShelfPerformanceTests {
    @MainActor func testBatchValidationMatchesIndividualReadsAndPerRecordFailures() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-batch-" + UUID().uuidString)
        let snapshot = try syntheticShelf(count: 4, root: root)
        let files = ShelfReadCounter(), store = MaterialStore(root: root)
        let counted = MaterialStore(root: root, files: files)
        _ = try await counted.load()
        let valid = await counted.presentationPayloads(for: snapshot.materials)
        XCTAssertEqual(valid.count, 4); XCTAssertEqual(files.payloadReads, 4)
        for record in snapshot.materials {
            let individual = try await store.payloadURL(of: record.id, versionID: record.activeVersionID)
            XCTAssertEqual(try valid[record.id]?.get(), individual)
        }
        let text = root.appendingPathComponent(snapshot.materials[0].activeVersion!.relativePath)
        var changed = try Data(contentsOf: text); changed[0] ^= 1; try changed.write(to: text)
        let image = root.appendingPathComponent(snapshot.materials[1].activeVersion!.relativePath)
        let saved = image.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: image, to: saved)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: saved)
        let pdf = root.appendingPathComponent(snapshot.materials[2].activeVersion!.relativePath)
        try FileManager.default.moveItem(at: pdf, to: pdf.appendingPathExtension("saved"))
        files.reset()
        let results = await counted.presentationPayloads(for: snapshot.materials)
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(files.payloadReads, 2, "Same-size tampering and the valid file must both be fully read")
        for record in snapshot.materials {
            let batch = try XCTUnwrap(results[record.id])
            let individual: Result<URL, Error>
            do { individual = .success(try await store.payloadURL(of: record.id, versionID: record.activeVersionID)) }
            catch { individual = .failure(error) }
            switch (individual, batch) {
            case (.success(let expected), .success(let actual)): XCTAssertEqual(actual, expected)
            case (.failure(let expected), .failure(let actual)):
                XCTAssertEqual((actual as NSError).domain, (expected as NSError).domain)
                XCTAssertEqual((actual as NSError).code, (expected as NSError).code)
            default: XCTFail("Batch and individual validation must agree for every record")
            }
        }
        let unchanged = try await counted.load(); XCTAssertEqual(unchanged, snapshot)
    }
}

extension ShelfPerformanceTests {
    @MainActor func testManualScrollSkipsArrivalButNewImportKeepsArrivalFeedback() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-arrival-" + UUID().uuidString)
        let snapshot = try syntheticShelf(count: 36, root: root)
        let line = Line(store: MaterialStore(root: root))
        line.revealed = true; line.resizeViewport(1200)
        try await line.load()
        XCTAssertTrue(line.claimArrival(snapshot.materials.last!.id))
        line.scroll(by: -line.maximumScrollOffset)
        XCTAssertFalse(line.claimArrival(snapshot.materials[0].id))
        let added = try await line.store.importMaterial(.text("Genuinely new synthetic card", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max)
        await line.render(added.snapshot)
        let id = try XCTUnwrap(added.snapshot.materials.last?.id)
        XCTAssertTrue(line.claimArrival(id), "A new import still gets its first arrival at the automatic scroll destination")
        XCTAssertFalse(line.claimArrival(id), "The same card must never replay arrival when revisited")
    }
}

extension ShelfPerformanceTests {
    @MainActor func testBatchWaitPreservesLandingAndTakeDownInteractionFlags() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/presentation-interaction-" + UUID().uuidString)
        let snapshot = try syntheticShelf(count: 4, root: root)
        let files = ShelfReadCounter()
        let line = Line(store: MaterialStore(root: root, files: files))
        try await line.load()
        let first = snapshot.materials[0].id, last = snapshot.materials[3].id
        line.beginFlight(first)
        let entered = expectation(description: "Batch validation suspended")
        let gate = DispatchSemaphore(value: 0)
        files.beforePayloadRead = { files.beforePayloadRead = nil; entered.fulfill(); _ = gate.wait(timeout: .now() + 2) }
        let pending = Task { await line.render(snapshot) }
        await fulfillment(of: [entered], timeout: 1)
        line.land(first); line.animateTakeDown(last)
        gate.signal(); await pending.value
        XCTAssertFalse(try XCTUnwrap(line.items.first(where: { $0.id == first })).flying)
        XCTAssertTrue(try XCTUnwrap(line.items.first(where: { $0.id == last })).falling)
    }
}

extension ShelfPerformanceTests {
    @MainActor func testPreparingDragRetainsNativeHostAcrossImportAndReleasesAfterFailure() async throws {
        try await checkPreparingDragAcrossImport(.failure)
    }
    @MainActor func testPreparingDragHandsRetainedHostToSessionThenReleasesOnCompletion() async throws {
        try await checkPreparingDragAcrossImport(.success)
    }
    @MainActor func testMouseUpCancelsPreparationAndReleasesRetainedHost() async throws {
        try await checkPreparingDragAcrossImport(.mouseUp)
    }
    @MainActor func testEscapeCancelsPreparationAndReleasesRetainedHost() async throws {
        try await checkPreparingDragAcrossImport(.escape)
    }
    @MainActor func testPrivacyRevokesPreparationEvenIfRestoredBeforeProviderReturns() async throws {
        try await checkPreparingDragAcrossImport(.privacy)
    }

    private enum PreparationOutcome { case success, failure, mouseUp, escape, privacy }

    @MainActor private func checkPreparingDragAcrossImport(_ outcome: PreparationOutcome) async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-dev/preparing-drag-" + UUID().uuidString)
        let initial = try syntheticShelf(count: 40, root: root)
        let store = MaterialStore(root: root), line = Line(store: store)
        try await line.load(); line.revealed = true; line.resizeViewport(1200)
        let host = LineHostingView(line: line)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        defer { panel.close() }
        line.scroll(by: -line.maximumScrollOffset)
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 100_000_000)
        let id = initial.materials[0].id
        var clicked: UUID?
        line.onCopy = { clicked = $0 }
        func descendants(_ view: NSView) -> [GrabView] { (view as? GrabView).map { [$0] } ?? view.subviews.flatMap(descendants) }
        let source = try XCTUnwrap(descendants(host).first { clicked = nil; $0.onClick(); return clicked == id })
        func mouse(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            let point = source.convert(NSPoint(x: source.bounds.midX + offset, y: source.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        var pending: CheckedContinuation<Void, Error>?
        let preparing = expectation(description: "real GrabView awaiting provider")
        let returned = expectation(description: "provider preparation returned")
        var prepared: NSFilePromiseProvider?
        var preparationWasCancelled = false
        line.onPrepareDrag = { card in
            defer { returned.fulfill() }
            XCTAssertEqual(card.id, id); XCTAssertEqual(card.versionID, initial.materials[0].activeVersionID)
            try await withCheckedThrowingContinuation { pending = $0; preparing.fulfill() }
            preparationWasCancelled = Task.isCancelled
            let provider = try await CopyOutProvider(store: store, id: card.id, versionID: card.versionID,
                suffix: "txt", canExport: { !line.snapshot.privacyHidden }).prepareProvider(exportRoot: root)
            prepared = provider
            return provider
        }
        var errors = 0; line.onError = { _ in errors += 1 }
        var starts = 0
        let dragged = try mouse(.leftMouseDragged, offset: 20)
        source.beginSession = { view, items, event in
            starts += 1
            XCTAssertTrue(view === source); XCTAssertTrue(view.window === panel)
            XCTAssertEqual(items.count, 1)
            XCTAssertTrue((items.first?.item as? NSFilePromiseProvider) === prepared)
            XCTAssertTrue(event === dragged)
            XCTAssertEqual(line.pressedID, id, "The press reservation must survive until the native handoff")
        }
        source.mouseDown(with: try mouse(.leftMouseDown)); source.mouseDragged(with: dragged)
        await fulfillment(of: [preparing], timeout: 2)
        XCTAssertEqual(line.pressedID, id, "Preparation must keep the existing press host alive")
        line.scroll(by: 500); XCTAssertEqual(line.scrollOffset, 0, "Preparing a drag must block manual shelf scrolling")
        let imported = try await store.importMaterial(.text("new synthetic import", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max)
        await line.render(imported.snapshot)
        // Let the normal spring removal complete; shorter delays can observe a
        // departing SwiftUI host and hide the original virtualization defect.
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 1_300_000_000)
        _ = try await renderFrame(host)
        XCTAssertGreaterThan(line.scrollOffset, 4000, "The import must actually move the source out of the viewport")
        XCTAssertTrue(descendants(host).contains { $0 === source }, "Import must retain the original native host while prepare is suspended")
        XCTAssertTrue(source.window === panel)
        switch outcome {
        case .mouseUp: source.mouseUp(with: try mouse(.leftMouseUp, offset: 20))
        case .escape: source.cancelOperation(nil)
        case .privacy:
            let coverNativeView = line.onPrivacyHide
            var coveringNativeView = false
            var coverCalls = 0
            let pressObserver = line.$pressedID.dropFirst().sink { _ in
                XCTAssertFalse(coveringNativeView,
                    "Press publication must precede native view teardown: " + Thread.callStackSymbols.joined(separator: "\n"))
            }
            defer { pressObserver.cancel() }
            line.onPrivacyHide = {
                coverCalls += 1
                XCTAssertNil(line.pressedID, "Privacy must revoke the press before synchronous host teardown")
                XCTAssertNil(line.cancelPress, "Host teardown must not own the live cancellation callback")
                coveringNativeView = true
                coverNativeView()
                coveringNativeView = false
            }
            var hidden = imported.snapshot; hidden.privacyHidden = true
            await line.render(hidden)
            XCTAssertEqual(coverCalls, 1)
            XCTAssertNil(line.pressedID); XCTAssertTrue(line.items.isEmpty)
            XCTAssertNil(line.cancelPress)
            XCTAssertFalse(source.isAccessibilityElement())
            XCTAssertNil(source.accessibilityLabel()); XCTAssertNil(source.accessibilityHelp())
            XCTAssertNil(source.dragImage)
            // No hidden frame is required for revocation: a quick restore must
            // not reactivate the old gesture even if SwiftUI coalesces updates.
            await line.render(imported.snapshot)
        case .success, .failure: break
        }
        if outcome == .mouseUp || outcome == .escape || outcome == .privacy { XCTAssertNil(line.pressedID) }
        if outcome == .failure { pending?.resume(throwing: StoreError.invalidSource) }
        else { pending?.resume() }
        await fulfillment(of: [returned], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        if outcome == .privacy { XCTAssertTrue(preparationWasCancelled, "Privacy must cancel the suspended task, not only hide its host") }
        XCTAssertEqual(errors, outcome == .failure ? 1 : 0)
        XCTAssertNil(line.pressedID, "Every preparation outcome releases its press reservation")
        if outcome == .success {
            XCTAssertEqual(starts, 1); XCTAssertEqual(line.draggingID, id)
            XCTAssertTrue(GrabView.isDragging)
            _ = try await renderFrame(host)
            XCTAssertTrue(descendants(host).contains { $0 === source })
            source.finishDrag()
            XCTAssertFalse(GrabView.isDragging)
        } else { XCTAssertEqual(starts, 0) }
        XCTAssertNil(line.draggingID)
        _ = try await renderFrame(host); try await Task.sleep(nanoseconds: 1_300_000_000)
        _ = try await renderFrame(host)
        XCTAssertFalse(descendants(host).contains { $0 === source })
        XCTAssertNil(source.window)
        if outcome == .privacy {
            // Revocation belongs to the old gesture; a fresh visible card must
            // still prepare its real provider and reach the native handoff.
            line.scroll(by: -line.maximumScrollOffset)
            _ = try await renderFrame(host)
            let restored = try XCTUnwrap(descendants(host).first { $0.materialID == id })
            XCTAssertFalse(restored === source)
            XCTAssertTrue(restored.isAccessibilityElement()); XCTAssertNotNil(restored.dragImage)
            let restarted = expectation(description: "fresh drag after privacy restoration")
            line.onPrepareDrag = { card in
                try await CopyOutProvider(store: store, id: card.id, versionID: card.versionID,
                    suffix: "txt", canExport: { !line.snapshot.privacyHidden }).prepareProvider(exportRoot: root)
            }
            restored.beginSession = { view, items, _ in
                XCTAssertTrue(view === restored); XCTAssertTrue(view.window === panel)
                XCTAssertEqual(items.count, 1)
                XCTAssertTrue(items.first?.item is NSFilePromiseProvider)
                restarted.fulfill()
            }
            func restoredMouse(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
                let point = restored.convert(NSPoint(x: restored.bounds.midX + offset, y: restored.bounds.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            restored.mouseDown(with: try restoredMouse(.leftMouseDown))
            restored.mouseDragged(with: try restoredMouse(.leftMouseDragged, offset: 20))
            await fulfillment(of: [restarted], timeout: 2)
            XCTAssertEqual(line.draggingID, id)
            restored.finishDrag()
            XCTAssertNil(line.draggingID)
        }
    }
}
