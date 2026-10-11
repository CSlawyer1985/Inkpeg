import AppKit
import SwiftUI
import XCTest
import InkpegCore
@testable import Inkpeg

final class IndependentRedRopeAuditTests: XCTestCase {
    @MainActor
    func testNativeFlippedBitmapUsesTrueExtendedQuadraticAtEverySample() throws {
        _ = NSApplication.shared
        for width: CGFloat in [400, 640, 800, 1200, 1728, 2560, 3840, 7680] {
            let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: width - 100, height: 64))
            let panel = LinePanel(content: target)
            defer { panel.close() }
            panel.setFrame(NSRect(x: 0, y: 0, width: width - 100, height: 64), display: false)
            target.frame = NSRect(x: 0, y: 0, width: width - 100, height: 64)
            target.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / button.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / button.bounds.height
            var red = [(CGFloat, CGFloat)]()
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.25 && color.redComponent > 0.45 && color.redComponent > 1.5 * color.greenComponent && color.redComponent > 1.5 * color.blueComponent {
                        red.append(((CGFloat(x) + 0.5) / scaleX, (CGFloat(y) + 0.5) / scaleY))
                    }
                }
            }
            XCTAssertFalse(red.isEmpty, "Native bitmap must include a real red stroke at width \(width)")
            let minRedX = try XCTUnwrap(red.map(\.0).min())
            let maxRedX = try XCTUnwrap(red.map(\.0).max())
            XCTAssertEqual(maxRedX - minRedX, 34 + 2.4, accuracy: 1, "34pt path plus the unchanged round caps must paint inside the 68pt hit target")
            XCTAssertEqual((minRedX + maxRedX) / 2, 34, accuracy: 0.6, "The shorter red segment must stay centered")
            XCTAssertGreaterThan(minRedX, 15); XCTAssertLessThan(maxRedX, 53)
            let region = button.frame.offsetBy(dx: 50, dy: 0)
            for sampleX: CGFloat in [20, 27, 34, 41, 48] {
                let samples = red.filter { abs($0.0 - sampleX) <= 0.75 }
                XCTAssertFalse(samples.isEmpty)
                let meanY = samples.map(\.1).reduce(0,+) / CGFloat(max(1, samples.count))
                let screenX = region.minX + sampleX
                let t = (screenX + 20) / (width + 40)
                let expectedY = Layout.ropeTop + 4 * Layout.sag(width: width) * t * (1 - t) - region.minY
                XCTAssertEqual(meanY, expectedY, accuracy: 0.9, "Flipped NSButton must paint on the SwiftUI neutral rope at width \(width), x \(sampleX)")
            }
            XCTAssertFalse(panel.isVisible)
        }
    }

    @MainActor
    func testContextSettingsKeyboardEquivalentAndAXPressRespectEnabledGuard() throws {
        _ = NSApplication.shared
        let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: 1100, height: 64))
        target.layoutSubtreeIfNeeded()
        let panel = LinePanel(content: target)
        defer { panel.close() }
        panel.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 64), display: false)
        target.frame = NSRect(x: 0, y: 0, width: 1100, height: 64)
        target.layoutSubtreeIfNeeded()
        var opened = 0, notes = 0
        target.onOpenSettings = { opened += 1 }; target.onNewNote = { notes += 1 }
        let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        let accessible = try XCTUnwrap(NSAccessibility.unignoredDescendant(of: button) as? NSButton)
        XCTAssertEqual(accessible.accessibilityRole(), .button)
        XCTAssertTrue(accessible.isAccessibilityElement())
        XCTAssertEqual(accessible.accessibilityLabel(), L(.noteNew))
        XCTAssertTrue(accessible.accessibilityPerformPress()); XCTAssertEqual(notes, 1); XCTAssertEqual(opened, 0)
        notes = 0
        XCTAssertEqual(button.accessibilityLabel(), L(.noteNew))
        XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertEqual(notes, 1)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(target.menu(for: event))
        let settings = try XCTUnwrap(menu.items.first { $0.title == L(.intakeSettings) })
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        XCTAssertTrue(menu.performKeyEquivalent(with: key)); XCTAssertEqual(opened, 1)
        target.canOpenSettings = { false }; target.canNewNote = { false }; target.refreshControls()
        XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertEqual(opened, 1); XCTAssertEqual(notes, 1)
        XCTAssertFalse(panel.isVisible); XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(button.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(target.registeredDraggedTypes.contains(.fileURL))
    }

    @MainActor
    func testDenseFullShelfRopeHitGridAndCardNearRopePreservation() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [400, 640, 800, 1200, 1728] {
            let count = max(3, min(12, Int((width - 200) / Layout.spacing)))
            let store = MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-independent-red-rope-data-" + UUID().uuidString))
            for i in 0..<count { _ = try await store.importMaterial(.text("synthetic audit card \(i)", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: count) }
            let line = Line(store: store); line.maxItems = count; try await line.load()
            line.revealed = true; line.canReceiveInput = true; line.canOpenIntakeSettings = true
            let host = LineHostingView(line: line), panel = LinePanel(content: host)
            defer { panel.close() }
            panel.setFrame(NSRect(x: 100, y: 100, width: width, height: Layout.panelHeight), display: false)
            host.frame = NSRect(x: 0, y: 0, width: width, height: Layout.panelHeight)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            host.layoutSubtreeIfNeeded()
            let target = try XCTUnwrap(descendants(host).compactMap { $0 as? LineDropTarget }.first)
            let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
            let rect = button.convert(button.bounds, to: host)
            for dx: CGFloat in stride(from: 18, through: 50, by: 1) {
                let x = rect.minX + dx, t = (x + 20) / (width + 40)
                let y = Layout.ropeTop + 4 * Layout.sag(width: width) * t * (1 - t)
                let actual = hit(host, NSPoint(x: x, y: y))
                XCTAssertTrue(actual === button, "width=\(width) ropePoint=(\(x),\(y)) actual=\(String(describing: actual))")
            }
            for grab in descendants(host).compactMap({ $0 as? GrabView }) {
                for x in [grab.bounds.minX + 6, grab.bounds.midX, grab.bounds.maxX - 6] {
                    let localY: CGFloat = grab.isFlipped ? 6 : grab.bounds.maxY - 6
                    let point = grab.convert(NSPoint(x: x, y: localY), to: host)
                    guard host.bounds.contains(point) else {
                        XCTAssertNil(hit(host, point), "Cards outside the scrolling viewport must not receive a click")
                        continue
                    }
                    let ropeT = (point.x + 20) / (width + 40)
                    let ropeY = Layout.ropeTop + 4 * Layout.sag(width: width) * ropeT * (1 - ropeT)
                    if abs(point.x - rect.midX) <= 17 && rect.contains(point) && abs(point.y - ropeY) <= 3 {
                        XCTAssertTrue(hit(host, point) === button, "The visible red cue may cross a swaying card; only that narrow curve owns the click")
                        continue
                    }
                    XCTAssertTrue(hit(host, point) === grab, "Card near-rope top must keep drag width=\(width) point=\(point) actual=\(String(describing: hit(host, point)))")
                }
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / width, scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
            for probeX in [rect.midX - 14, rect.midX, rect.midX + 14] {
                var rows = [CGFloat]()
                let pixelX = Int(probeX * scaleX)
                for y in 0..<min(bitmap.pixelsHigh, Int(64 * scaleY)) {
                    guard let color = bitmap.colorAt(x: pixelX, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.25 && color.redComponent > 0.45 && color.redComponent > 1.5 * color.greenComponent && color.redComponent > 1.5 * color.blueComponent { rows.append((CGFloat(y) + 0.5) / scaleY) }
                }
                XCTAssertFalse(rows.isEmpty, "Hidden compositor must paint red over swaying cards")
                let t = (probeX + 20) / (width + 40), expected = Layout.ropeTop + 4 * Layout.sag(width: width) * t * (1 - t)
                let centroid = rows.reduce(0,+) / CGFloat(max(1, rows.count))
                XCTAssertEqual(centroid, expected, accuracy: 0.9, "Native and SwiftUI red strokes must coincide")
                if let min = rows.min(), let max = rows.max() { XCTAssertLessThanOrEqual(max - min, 3.5, "Two red strokes must not split or thicken visibly") }
            }
            XCTAssertFalse(panel.isVisible)
        }
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func hit(_ host: NSView, _ point: NSPoint) -> NSView? { host.hitTest(host.superview.map { host.convert(point, to: $0) } ?? point) }
}
