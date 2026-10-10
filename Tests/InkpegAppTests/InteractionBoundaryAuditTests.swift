import AppKit
import SwiftUI
import XCTest
import InkpegCore
@testable import Inkpeg

final class InteractionBoundaryAuditTests: XCTestCase {
    @MainActor
    func testExistingCardsKeepNativeGrabIdentityInsideAndBelowInputStrip() async throws {
        let (line, host, panel) = try await fixture(width: 1200, cardCount: 5)
        defer { panel.close() }
        let grabs = descendants(host).compactMap { $0 as? GrabView }
        XCTAssertEqual(grabs.count, 5)
        var copies = 0; line.onCopy = { _ in copies += 1 }
        for grab in grabs {
            let top = grab.convert(NSPoint(x: grab.bounds.midX, y: grab.isFlipped ? 10 : grab.bounds.height - 10), to: host)
            XCTAssertTrue(line.inputRegion(width: 1200).contains(top), "Probe must be in the actual shared 64px band: \(top)")
            XCTAssertTrue(hit(host, top) === grab, "Input target must preserve the existing card at \(top); hit=\(String(describing: hit(host, top)))")
            let lower = grab.convert(NSPoint(x: grab.bounds.midX, y: grab.isFlipped ? 80 : grab.bounds.height - 80), to: host)
            XCTAssertFalse(line.inputRegion(width: 1200).contains(lower))
            XCTAssertTrue(hit(host, lower) === grab)
            XCTAssertTrue(grab.accessibilityPerformPress())
        }
        XCTAssertEqual(copies, 5)
        XCTAssertFalse(panel.isVisible); XCTAssertFalse(panel.isKeyWindow)
    }

    @MainActor
    func testNativeRedRopeIsInsideStripAcrossWidthsAndLanguages() async throws {
        let previous = appLocalizer; defer { appLocalizer = previous }
        for locale in ["zh-Hans", "en", "es"] {
            appLocalizer = Localizer(localeIdentifier: locale)
            for width: CGFloat in [400, 640, 800, 1200] {
                let (line, host, panel) = try await fixture(width: width, cardCount: 0)
                defer { panel.close() }
                let buttons = descendants(host).compactMap { $0 as? NSButton }
                XCTAssertEqual(buttons.count, 1)
                for button in buttons {
                    let rect = button.convert(button.bounds, to: host)
                    XCTAssertTrue(line.inputRegion(width: width).contains(rect), "\(locale), width\(width), actual button \(button.title) rect\(rect)")
                    XCTAssertTrue(hit(host, NSPoint(x: rect.midX, y: rect.midY)) === button)
                    XCTAssertTrue(button.acceptsFirstMouse(for: nil))
                }
                if let button = buttons.first {
                    XCTAssertEqual(button.title, "")
                    XCTAssertEqual(button.accessibilityLabel(), L(.noteNew))
                }
                XCTAssertFalse(panel.isVisible)
            }
        }
    }

    @MainActor
    func testFullShelfStillLeavesRedRopeSettingsCenterAndCornersReachable() async throws {
        let previous = appLocalizer; defer { appLocalizer = previous }
        for locale in ["zh-Hans", "en", "es"] {
            appLocalizer = Localizer(localeIdentifier: locale)
            for width: CGFloat in [640, 800, 1200] {
                let capacity = max(3, min(12, Int((width - 200) / Layout.spacing)))
                let (line, host, panel) = try await fixture(width: width, cardCount: capacity)
                defer { panel.close() }
                let buttons = descendants(host).compactMap { $0 as? NSButton }
                XCTAssertEqual(buttons.count, 1)
                for button in buttons {
                    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
                    XCTAssertTrue(line.inputRegion(width: width).contains(point))
                    XCTAssertTrue(hit(host, point) === button, "\(locale), width\(width), full\(capacity) cards obscure \(button.title) at \(point); actual=\(String(describing: hit(host, point)))")
                    // Upper corners retain the generous hit width. At the
                    // lower edge, only the shorter visible red cue takes
                    // priority over a swinging card.
                    for local in [NSPoint(x: 6, y: 6), NSPoint(x: button.bounds.maxX - 6, y: 6), NSPoint(x: button.bounds.midX - 14, y: button.bounds.maxY - 6), NSPoint(x: button.bounds.midX + 14, y: button.bounds.maxY - 6)] {
                        let edge = button.convert(local, to: host)
                        XCTAssertTrue(hit(host, edge) === button, "\(locale), width\(width), control edge \(button.title) at \(edge) must be reachable")
                    }
                }
                XCTAssertFalse(panel.isVisible)
            }
        }
    }

    @MainActor private func fixture(width: CGFloat, cardCount: Int) async throws -> (Line, NSHostingView<LineView>, LinePanel) {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-boundary-audit-" + UUID().uuidString))
        for i in 0..<cardCount { _ = try await store.importMaterial(.text("合成审计卡片 \(i)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: cardCount) }
        let line = Line(store: store); line.maxItems = max(3, cardCount); try await line.load()
        line.revealed = true; line.canReceiveInput = true; line.canOpenIntakeSettings = true
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: width, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: width, height: Layout.panelHeight)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try await Task.sleep(nanoseconds: 750_000_000)
        host.layoutSubtreeIfNeeded()
        return (line, host, panel)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func hit(_ host: NSView, _ point: NSPoint) -> NSView? {
        host.hitTest(host.superview.map { host.convert(point, to: $0) } ?? point)
    }
}
