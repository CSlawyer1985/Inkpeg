import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class ScrollableShelfTests: XCTestCase {
    @MainActor
    func testDefaultShelfKeepsEveryCardBeyondScreenCapacity() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-scroll-test-" + UUID().uuidString)
        let store = MaterialStore(root: root), line = Line(store: store)
        var expected = [UUID]()
        for index in 0..<20 {
            let result = try await store.importMaterial(.text("滚动材料 \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: line.maxItems)
            if case .hanging(let id) = result.disposition { expected.append(id) }
        }
        try await line.load()
        XCTAssertEqual(line.items.map(\.id), expected)
        XCTAssertEqual(line.snapshot.materials.filter { $0.status == .hanging }.count, 20)
        XCTAssertTrue(line.snapshot.materials.allSatisfy { $0.status == .hanging })
    }
}

extension ScrollableShelfTests {
    @MainActor
    func testScrollClampsAtBothEndsAndResizeDoesNotChangeStoredState() async throws {
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-scroll-test-" + UUID().uuidString)), line = Line(store: store)
        for index in 0..<20 { _ = try await store.importMaterial(.text("边界 \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: line.maxItems) }
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let original = try await store.load()
        line.scroll(by: -100_000); XCTAssertEqual(line.scrollOffset, 0)
        let before = line.cardX(index: 0, width: 800)
        line.scroll(by: 160)
        XCTAssertEqual(line.cardX(index: 0, width: 800), before - 160, accuracy: 0.01)
        line.scroll(by: 100_000); XCTAssertEqual(line.scrollOffset, line.maximumScrollOffset)
        line.resizeViewport(400); XCTAssertEqual(line.items.count, 20)
        line.resizeViewport(5000); XCTAssertEqual(line.scrollOffset, 0)
        XCTAssertEqual(line.maximumScrollOffset, 0)
        let unchanged = try await store.load(); XCTAssertEqual(unchanged, original)
    }

    @MainActor
    func testNativeHorizontalAndShiftWheelMoveShelfButVerticalDoesNot() async throws {
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-scroll-test-" + UUID().uuidString)), line = Line(store: store)
        for index in 0..<10 { _ = try await store.importMaterial(.text("手势 \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: line.maxItems) }
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let host = LineHostingView(line: line)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        host.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(line.scrollOffset, 120, accuracy: 0.01)
        let vertical = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0))
        host.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: vertical)))
        XCTAssertEqual(line.scrollOffset, 120, accuracy: 0.01)
        vertical.flags = .maskShift
        host.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: vertical)))
        XCTAssertGreaterThan(line.scrollOffset, 120)
        line.revealed = false
        let hidden = line.scrollOffset; host.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(line.scrollOffset, hidden)
    }
}

extension ScrollableShelfTests {
    @MainActor
    func testScrollOverActualCardReachesShelf() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-scroll-test-" + UUID().uuidString)), line = Line(store: store)
        for index in 0..<10 { _ = try await store.importMaterial(.text("卡片事件 \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: line.maxItems) }
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let card = try XCTUnwrap(descendants(host).compactMap { $0 as? GrabView }.first)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        card.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(line.scrollOffset, 120, accuracy: 0.01)
    }
}

extension ScrollableShelfTests {
    @MainActor
    func testScrollingKeepsCardViewsStableInsteadOfReplayingArrival() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-scroll-test-" + UUID().uuidString)), line = Line(store: store)
        for index in 0..<10 { _ = try await store.importMaterial(.text("连续滚动 \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: line.maxItems) }
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight)
        defer { panel.close() }
        func cards(_ view: NSView) -> [GrabView] { (view as? GrabView).map { [$0] } ?? view.subviews.flatMap(cards) }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000)
        let before = Set(cards(host).map(ObjectIdentifier.init))
        XCTAssertEqual(before.count, 10)
        line.scroll(by: 700)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Set(cards(host).map(ObjectIdentifier.init)), before)
    }
}


extension ScrollableShelfTests {
    @MainActor
    func testOverflowCountsCardEdgesSoBothEndCardsRemainReachable() async throws {
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-scroll-test-" + UUID().uuidString)), line = Line(store: store)
        for index in 0..<9 { _ = try await store.importMaterial(.text("完整边缘 \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: line.maxItems) }
        try await line.load(); line.revealed = true; line.resizeViewport(1440)
        let original = try await store.load()
        XCTAssertGreaterThan(line.maximumScrollOffset, 0, "Pin centres fitting does not mean card edges fit")
        XCTAssertGreaterThanOrEqual(line.cardX(index: 0, width: 1440) - Layout.cardWidth / 2, 0)
        line.scroll(by: 100_000)
        XCTAssertLessThanOrEqual(line.cardX(index: 8, width: 1440) + Layout.cardWidth / 2, 1440)
        XCTAssertEqual(line.items.count, 9)
        let unchanged = try await store.load(); XCTAssertEqual(unchanged, original)
    }
}


extension ScrollableShelfTests {
    @MainActor
    func testNativeBlankHitAndVisibleCardsForZeroFourNineFifty() async throws {
        _ = NSApplication.shared
        for count in [0, 4, 9, 50] {
            let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-hit-test-" + UUID().uuidString))
            let line = Line(store: store)
            for index in 0..<count { _ = try await store.importMaterial(.text("Hit fixture \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max) }
            try await line.load(); line.revealed = true; line.resizeViewport(800)
            let host = LineHostingView(line: line), panel = LinePanel(content: host)
            panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
            host.frame = NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 1_300_000_000)
            host.layoutSubtreeIfNeeded()
            panel.updateMousePassThrough(at: panel.convertPoint(toScreen: NSPoint(x: 8, y: 15)))
            XCTAssertTrue(panel.ignoresMouseEvents, "Actual window gate must ignore blanks")
            if count >= 9 {
                XCTAssertTrue(line.acceptsClick(at: line.pageControlsRegion(width: 800).centerForTest, width: 800))
            }
            XCTAssertNil(host.hitTest(NSPoint(x: 8, y: 195)), "Blank must pass through, count=\(count)")
            if count > 0 {
                XCTAssertFalse(line.hitRects.isEmpty)
                for rect in line.hitRects.values where rect.width > 30 && rect.height > 30 {
                    XCTAssertNotNil(host.hitTest(NSPoint(x: rect.midX, y: rect.midY)), "Visible card must receive input")
                }
            }
            line.scroll(by: -100_000); XCTAssertEqual(line.scrollOffset, 0)
            line.scroll(by: 100_000); XCTAssertEqual(line.scrollOffset, line.maximumScrollOffset)
            panel.close()
        }
    }
}


private extension CGRect { var centerForTest: CGPoint { CGPoint(x: midX, y: midY) } }

extension ScrollableShelfTests {
    @MainActor
    func testBlankPassesThroughWhileCardWheelAndPageControlsRemainAvailable() async throws {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-wheel-test-" + UUID().uuidString)), line = Line(store: store)
        for index in 0..<9 { _ = try await store.importMaterial(.text("Wheel fixture \(index)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: Int.max) }
        try await line.load(); line.revealed = true; line.resizeViewport(800)
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        defer { panel.close() }
        panel.orderFrontRegardless()
        let point = panel.convertPoint(toScreen: NSPoint(x: 8, y: 15))
        panel.updateMousePassThrough(at: point)
        XCTAssertTrue(panel.ignoresMouseEvents)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertNil(host.hitTest(NSPoint(x: 8, y: 195)))
        XCTAssertEqual(line.scrollOffset, 0, "Blank has no wheel receiver in this window")
        host.scrollWheel(with: wheel)
        XCTAssertEqual(line.scrollOffset, 120, accuracy: 0.01)
        XCTAssertTrue(panel.ignoresMouseEvents)
        line.pressedID = line.items[0].id
        host.scrollWheel(with: wheel)
        XCTAssertEqual(line.scrollOffset, 120, "Pressed source must not jump")
        line.pressedID = nil
        line.scrollPage(forward: true); XCTAssertGreaterThan(line.scrollOffset, 120)
        line.scrollPage(forward: false); XCTAssertLessThan(line.scrollOffset, line.maximumScrollOffset)
        line.revealed = false
        let hiddenOffset = line.scrollOffset
        host.scrollWheel(with: wheel)
        XCTAssertEqual(line.scrollOffset, hiddenOffset)

    }
}
