import AppKit
import SwiftUI
import XCTest
import InkpegCore
@testable import Inkpeg

final class RedRopeSettingsTests: XCTestCase {
    // Approved 2026-10-09: the same rope target now opens notes; settings move
    // to its context menu. Geometry, first-click and AX guards remain strict.
    @MainActor
    func testActualUnignoredAccessibilityElementHasSettingsNameAndPress() throws {
        let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: 1100, height: 64))
        target.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        let exposed = NSAccessibility.unignoredDescendant(of: button) as AnyObject?
        XCTAssertTrue(exposed === button, "Accessibility must expose the named rope control, not an unnamed cell")
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), settingsName)
        var opened = 0; target.onNewNote = { opened += 1 }
        XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertEqual(opened, 1)
        target.canNewNote = { false }; target.refreshControls()
        XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testVisibleControlsBecomeOneUnlabelledAccessibleRopeSegment() throws {
        let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: 1100, height: 64))
        target.layoutSubtreeIfNeeded()
        let controls = target.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(controls.count, 1, "The visible paste button must be removed")
        let settings = try XCTUnwrap(controls.first { $0.title == L(.intakeSettings) || $0.accessibilityLabel() == settingsName })
        XCTAssertEqual(settings.title, "", "The segment must not show a text button")
        XCTAssertEqual(settings.accessibilityLabel(), settingsName)
        XCTAssertEqual(settings.toolTip, L(.noteHint))
        XCTAssertFalse(settings.isBordered)
        XCTAssertTrue(settings.acceptsFirstMouse(for: nil))
        XCTAssertTrue(settings.acceptsFirstResponder)
        var opened = 0; target.onNewNote = { opened += 1 }
        XCTAssertTrue(settings.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)
        target.canReceive = { false }; target.refreshControls()
        XCTAssertTrue(settings.isEnabled, "Busy intake must not block settings")
    }

    @MainActor
    func testSegmentFollowsTheActualExtendedQuadraticRopeAcrossWidthsAndFullShelves() async throws {
        for width: CGFloat in [400, 640, 800, 1200, 1728] {
            let capacity = max(3, min(12, Int((width - 200) / Layout.spacing)))
            let (line, host, panel, target) = try await fixture(width: width, count: capacity)
            defer { panel.close() }
            let settings = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first { $0.title == L(.intakeSettings) || $0.accessibilityLabel() == settingsName })
            let rect = settings.convert(settings.bounds, to: host)
            XCTAssertEqual(rect.midX, width * 0.6180339887498949, accuracy: 0.01)
            XCTAssertEqual(rect.width, 68, accuracy: 0.01)
            for x in [rect.midX - 14, rect.midX, rect.midX + 14] {
                let f = (x + 20) / (width + 40)
                let y = Layout.ropeTop + 4 * Layout.sag(width: width) * f * (1 - f)
                let ropePoint = NSPoint(x: x, y: y)
                XCTAssertTrue(rect.contains(ropePoint), "The red stroke must lie on the real rope")
                XCTAssertTrue(hit(host, ropePoint) === settings, "Full shelf width \(width) must leave the red rope reachable at \(ropePoint); actual hit \(String(describing: hit(host, ropePoint))); control rect \(rect)")
                let generousPoint = NSPoint(x: x, y: y - 12)
                XCTAssertTrue(hit(host, generousPoint) === settings, "The transparent target must be easier to click than a thin stroke")
                XCTAssertTrue(line.inputRegion(width: width).contains(generousPoint))
            }
            for x in [rect.minX + 6, rect.maxX - 6] {
                let f = (x + 20) / (width + 40)
                let upperHit = NSPoint(x: x, y: Layout.ropeTop + 4 * Layout.sag(width: width) * f * (1 - f) - 12)
                XCTAssertTrue(hit(host, upperHit) === settings, "The generous 68pt upper hit area must survive shortening the visible cue")
            }
            for grab in descendants(host).compactMap({ $0 as? GrabView }) {
                let top = grab.convert(NSPoint(x: grab.bounds.midX, y: grab.isFlipped ? 10 : grab.bounds.height - 10), to: host)
                if host.bounds.contains(top) {
                    XCTAssertTrue(hit(host, top) === grab, "The settings hit target must not steal a visible card drag")
                } else {
                    XCTAssertNil(hit(host, top), "Cards outside the scrolling viewport must not receive a click")
                }
            }
            XCTAssertTrue(settings.registeredDraggedTypes.isEmpty, "External drops must resolve to the existing receiver ancestor")
            XCTAssertTrue(target.registeredDraggedTypes.contains(.fileURL))
            XCTAssertFalse(panel.isVisible); XCTAssertFalse(panel.canBecomeKey)
        }
    }

    @MainActor
    func testRevealAndResizeKeepSettingsWithTheRopeWithoutEnablingHiddenInput() async throws {
        let (line, host, panel, target) = try await fixture(width: 1200, count: 0)
        defer { panel.close() }
        line.revealed = false; await settle(host)
        XCTAssertFalse(target.canOpenSettings(), "A tucked-away segment must not open settings")
        XCTAssertTrue(line.inputRegion(width: 1200).isEmpty)
        line.revealed = true
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight)
        await settle(host)
        let settings = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        let rect = settings.convert(settings.bounds, to: host)
        XCTAssertEqual(rect.midX, 800 * 0.6180339887498949, accuracy: 0.01)
        XCTAssertTrue(target.canOpenSettings())
        XCTAssertTrue(hit(host, NSPoint(x: rect.midX, y: rect.midY)) === settings)
    }

    @MainActor private var settingsName: String { L(.noteNew) }
    @MainActor private func fixture(width: CGFloat, count: Int) async throws -> (Line, NSHostingView<LineView>, LinePanel, LineDropTarget) {
        _ = NSApplication.shared
        let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-red-rope-test-" + UUID().uuidString))
        for i in 0..<count { _ = try await store.importMaterial(.text("合成红绳卡片 \(i)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: count) }
        let line = Line(store: store); line.maxItems = max(3, count); try await line.load()
        line.revealed = true; line.canReceiveInput = true; line.canOpenIntakeSettings = true
        let host = LineHostingView(line: line), panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: width, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: width, height: Layout.panelHeight)
        await settle(host)
        return (line, host, panel, try XCTUnwrap(descendants(host).compactMap { $0 as? LineDropTarget }.first))
    }
    @MainActor private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 750_000_000)
        host.layoutSubtreeIfNeeded()
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func hit(_ host: NSView, _ point: NSPoint) -> NSView? { host.hitTest(host.superview.map { host.convert(point, to: $0) } ?? point) }
}
