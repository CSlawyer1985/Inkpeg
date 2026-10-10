import AppKit
import SwiftUI
import XCTest
import InkpegCore
@testable import Inkpeg

final class LineInputHostingTests: XCTestCase {
    @MainActor
    func testNativePasteMenuInvokesActionWithoutTakingFocus() throws {
        _ = NSApplication.shared
        let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: 1100, height: 64))
        let panel = LinePanel(content: target)
        defer { panel.close() }
        var pasteCount = 0
        target.onPaste = { pasteCount += 1 }
        XCTAssertTrue(target.acceptsFirstMouse(for: nil))
        let item = try pasteMenuItem(target)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(pasteCount, 1)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isVisible)
    }
    @MainActor
    func testRopeOffersSettingsEvenWhenManualIntakeIsUnavailable() throws {
        let target = LineDropTarget(frame: NSRect(x: 0, y: 0, width: 1100, height: 64))
        target.canReceive = { false }
        var settingsCount = 0
        target.onOpenSettings = { settingsCount += 1 }
        target.refreshControls()
        let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(button.menu(for: event))
        let settings = try XCTUnwrap(menu.items.first { $0.title == L(.intakeSettings) })
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertEqual(settingsCount, 1)
    }
    @MainActor
    func testRealHostedInputRegionTracksTheVisibleRopeBand() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/inkpeg-hosted-input-" + UUID().uuidString)
        let line = Line(store: MaterialStore(root: root))
        try await line.load()
        line.revealed = true; line.canReceiveInput = true
        let host = LineHostingView(line: line)
        let panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 1200, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: Layout.panelHeight)
        defer { panel.close() }
        await settle(host)
        func receivers(_ view: NSView) -> [LineDropTarget] {
            (view as? LineDropTarget).map { [$0] } ?? view.subviews.flatMap(receivers)
        }
        let targets = receivers(host)
        XCTAssertEqual(targets.count, 1, "The real hosted native drop target must exist")
        if let target = targets.first {
            XCTAssertFalse(target.bounds.isEmpty, "The drop target must have a real nonempty layout: \(target.frame)")
            let rect = target.convert(target.bounds, to: host)
            let band = host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            XCTAssertEqual(band, line.inputRegion(width: panel.frame.width))
            XCTAssertTrue(band.contains(CGPoint(x: 1100, y: 32)), "Native receiver must sit beneath visible input controls, actual band: \(band)")
            target.layoutSubtreeIfNeeded()
            let localPoint = NSPoint(x: 1100, y: host.isFlipped ? 32 : Layout.panelHeight - 32)
            let nativeHit = target.hitTest(target.superview!.convert(localPoint, from: host))
            XCTAssertTrue(nativeHit?.acceptsFirstMouse(for: nil) == true, "Direct native hit: \(String(describing: nativeHit)); target: \(target.frame), buttons: \(target.subviews.map(\.frame))")
        }
        XCTAssertFalse(line.inputRegion(width: panel.frame.width).isEmpty, "Production mouse gate must use the visible input region")
        XCTAssertTrue(line.inputRegion(width: panel.frame.width).contains(CGPoint(x: 1100, y: 32)), "Visible paste control must fall inside the mouse receiving region")
        XCTAssertTrue(line.inputRegion(width: panel.frame.width).contains(CGPoint(x: 200, y: 32)), "The rope drop area must fall inside the mouse receiving region")
        XCTAssertFalse(line.inputRegion(width: panel.frame.width).contains(CGPoint(x: 200, y: 180)), "The lower transparent panel must pass through mouse events")
        let point = NSPoint(x: 1100, y: host.isFlipped ? 32 : Layout.panelHeight - 32)
        let hit = try XCTUnwrap(hostedHit(host, point))
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil), "The input band must receive a first click while the panel cannot become key; actual hit: \(type(of: hit))")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.isVisible, "This integration test never displays a window")
    }

    @MainActor
    func testHostedRedRopeAndPasteMenuInvokeLineCallbacks() async throws {
        let (line, host, panel, target) = try await makeHostedLine()
        defer { panel.close() }
        var pastes = 0, settings = 0, notes = 0
        line.onPasteInput = { pastes += 1 }; line.onOpenIntakeSettings = { settings += 1 }
        line.onNewNote = { notes += 1 }
        let buttons = target.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)
        for button in buttons {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
            XCTAssertTrue(line.inputRegion(width: panel.frame.width).contains(center), "Both controls must be inside the receiving band")
            XCTAssertTrue(hostedHit(host, center) === button, "The real host must deliver the mouse to \(button.title)")
            XCTAssertTrue(button.acceptsFirstMouse(for: nil)); button.performClick(nil)
        }
        let item = try pasteMenuItem(target)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(target.menu(for: event))
        let setting = try XCTUnwrap(menu.items.first { $0.title == L(.intakeSettings) })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(setting.action), to: setting.target, from: setting))
        XCTAssertEqual(pastes, 1); XCTAssertEqual(settings, 1)
        XCTAssertEqual(notes, 1)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isKeyWindow); XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testHostedDropSurvivesHoverOverlayAndPreservesOriginalFile() async throws {
        let (line, host, panel, target) = try await makeHostedLine()
        defer { panel.close() }
        let source = URL(fileURLWithPath: "/tmp/inkpeg-hosted-source-" + UUID().uuidString + ".txt")
        let bytes = Data("合成宿主拖放文件".utf8); try bytes.write(to: source)
        let board = NSPasteboard(name: .init("InkpegHostedDrop-" + UUID().uuidString))
        let item = NSPasteboardItem(); item.setString(source.absoluteString, forType: .fileURL)
        XCTAssertTrue(board.writeObjects([item]))
        let service = ClipboardImportService(gateway: HostedEmptyBoard(), store: line.store)
        await service.start()
        let saved = expectation(description: "Hosted drop copied into managed storage")
        line.onReceiveInput = { service.enqueueManual($0) }
        service.onSnapshot = { snapshot in await line.render(snapshot); saved.fulfill() }
        // The empty hint sits below the band; its hover overlay must leave this drop point reachable.
        let center = NSPoint(x: 600, y: 60)
        XCTAssertTrue(hostedHit(host, center) === target)
        XCTAssertEqual(target.updateHover(from: board), .copy)
        await settle(host)
        XCTAssertEqual(line.dropCount, 1)
        XCTAssertTrue(hostedHit(host, center) === target, "Hover highlight must not intercept the drop")
        XCTAssertTrue(target.receive(from: board))
        await fulfillment(of: [saved], timeout: 2)
        let snapshot = try await line.store.load(), record = try XCTUnwrap(snapshot.materials.first)
        XCTAssertEqual(record.source.origin, .drop)
        let owned = try await line.store.payloadURL(of: record.id, versionID: record.activeVersionID)
        XCTAssertNotEqual(owned, source)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: owned), bytes)
        XCTAssertEqual(line.dropCount, 0)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testResizeAndHideUpdateTheNativeReceivingBand() async throws {
        let (line, host, panel, target) = try await makeHostedLine()
        defer { panel.close() }
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: Layout.panelHeight)
        await settle(host)
        XCTAssertEqual(line.inputRegion(width: panel.frame.width), LineInputLayout.region(width: 800))
        XCTAssertFalse(line.inputRegion(width: panel.frame.width).contains(NSPoint(x: 780, y: 32)))
        XCTAssertFalse(line.inputRegion(width: panel.frame.width).contains(NSPoint(x: 300, y: 180)))
        line.revealed = false; await settle(host)
        XCTAssertTrue(line.inputRegion(width: panel.frame.width).isEmpty)
        XCTAssertFalse(target.canReceive())
        line.revealed = true; await settle(host, delay: 600_000_000)
        XCTAssertEqual(line.inputRegion(width: panel.frame.width), LineInputLayout.region(width: 800))
        XCTAssertTrue(target.canReceive())
        let rect = target.convert(target.bounds, to: host)
        let band = host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        XCTAssertEqual(band, line.inputRegion(width: panel.frame.width), "The final native band must match the production receiving region")
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testBusyAndPrivacyDisableInputButKeepHostedSettingsReachable() async throws {
        let (line, host, panel, target) = try await makeHostedLine()
        defer { panel.close() }
        let board = NSPasteboard(name: .init("InkpegHostedGuard-" + UUID().uuidString))
        board.setString("合成隐私文字", forType: .string)
        let settings = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        var settingsCount = 0; line.onOpenIntakeSettings = { settingsCount += 1 }
        for hidden in [false, true] {
            line.canReceiveInput = hidden
            var snapshot = line.snapshot; snapshot.privacyHidden = hidden
            await line.render(snapshot)
            await settle(host)
            XCTAssertFalse(try pasteMenuItem(target).isEnabled)
            XCTAssertEqual(settings.isEnabled, !hidden, "The approved note action is disabled while previews are hidden")
            XCTAssertFalse(target.receive(from: board)); XCTAssertEqual(target.updateHover(from: board), [])
            let center = settings.convert(NSPoint(x: settings.bounds.midX, y: settings.bounds.midY), to: host)
            XCTAssertTrue(line.inputRegion(width: panel.frame.width).contains(center))
            XCTAssertTrue(hostedHit(host, center) === settings)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let menu = try XCTUnwrap(settings.menu(for: event))
            let item = try XCTUnwrap(menu.items.first { $0.title == L(.intakeSettings) })
            XCTAssertTrue(item.isEnabled, "Settings remain reachable through the rope menu during privacy/busy states")
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(settingsCount, 2)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testHostedPasteMenuImportsPrivateClipboardThroughTheProductionLineHook() async throws {
        let (line, host, panel, target) = try await makeHostedLine()
        defer { panel.close() }
        let board = NSPasteboard(name: .init("InkpegHostedPaste-" + UUID().uuidString))
        let text = "合成按钮粘贴材料"; board.setString(text, forType: .string)
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: line.store)
        let intake = LineIntakeController(line: line, service: service)
        let finished = expectation(description: "Actual paste menu saves managed text")
        service.onSnapshot = { await line.render($0) }
        service.onImported = { _, _ in intake.imported() }
        service.onStateChanged = { intake.refresh(); if line.inputFeedback == L(.inputSaved) { finished.fulfill() } }
        await service.start(); await settle(host)
        let button = try XCTUnwrap(target.subviews.compactMap { $0 as? NSButton }.first)
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
        XCTAssertTrue(hostedHit(host, center) === button)
        let item = try pasteMenuItem(target)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await fulfillment(of: [finished], timeout: 2)
        let snapshot = try await line.store.load(), record = try XCTUnwrap(snapshot.materials.first)
        let owned = try await line.store.payloadURL(of: record.id, versionID: record.activeVersionID)
        XCTAssertEqual(try String(contentsOf: owned, encoding: .utf8), text)
        XCTAssertEqual(record.source.origin, .clipboard)
        XCTAssertEqual(line.inputFeedback, L(.inputSaved))
        await settle(host)
        let label = try XCTUnwrap(target.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, L(.inputSaved))
        XCTAssertLessThanOrEqual(label.frame.maxY, LineInputLayout.controlHeight)
        XCTAssertFalse(label.frame.intersects(button.frame), "Feedback must leave the native control accessible")
        XCTAssertFalse(panel.isKeyWindow); XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testOrdinaryHostingRoutesNativeButtonsAndEmptyDropBandWithoutForwarding() async throws {
        let (line, host, panel, target) = try await makeHostedLine(forwarding: false)
        defer { panel.close() }
        var pastes = 0, settings = 0, notes = 0
        line.onPasteInput = { pastes += 1 }; line.onOpenIntakeSettings = { settings += 1 }
        line.onNewNote = { notes += 1 }
        for button in target.subviews.compactMap({ $0 as? NSButton }) {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
            XCTAssertTrue(hostedHit(host, center) === button)
            XCTAssertTrue(button.acceptsFirstMouse(for: nil)); button.performClick(nil)
        }
        let item = try pasteMenuItem(target)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(target.menu(for: event))
        let settingsItem = try XCTUnwrap(menu.items.first { $0.title == L(.intakeSettings) })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settingsItem.action), to: settingsItem.target, from: settingsItem))
        XCTAssertEqual(pastes, 1); XCTAssertEqual(settings, 1)
        XCTAssertEqual(notes, 1)
        XCTAssertTrue(hostedHit(host, NSPoint(x: 600, y: 60)) === target)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor private func makeHostedLine(forwarding: Bool = true) async throws -> (Line, NSHostingView<LineView>, LinePanel, LineDropTarget) {
        _ = NSApplication.shared
        let line = Line(store: MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-hosted-fixture-" + UUID().uuidString)))
        try await line.load()
        line.revealed = true; line.canReceiveInput = true; line.canOpenIntakeSettings = true
        let host = forwarding ? LineHostingView(line: line) : NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.setFrame(NSRect(x: 100, y: 100, width: 1200, height: Layout.panelHeight), display: false)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: Layout.panelHeight)
        await settle(host)
        func targets(_ view: NSView) -> [LineDropTarget] { (view as? LineDropTarget).map { [$0] } ?? view.subviews.flatMap(targets) }
        return (line, host, panel, try XCTUnwrap(targets(host).first))
    }
    // AppKit hitTest accepts coordinates in the superview, not in the receiver.
    @MainActor private func pasteMenuItem(_ target: LineDropTarget) throws -> NSMenuItem {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        return try XCTUnwrap(target.menu(for: event)?.items.first { $0.title == L(.pasteInput) })
    }
    @MainActor private func hostedHit(_ host: NSView, _ local: NSPoint) -> NSView? {
        host.hitTest(host.superview.map { host.convert(local, to: $0) } ?? local)
    }
    @MainActor private func settle(_ host: NSView, delay: UInt64 = 30_000_000) async {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try? await Task.sleep(nanoseconds: delay)
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor private final class HostedEmptyBoard: ClipboardGateway {
    var changeCount = 1
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 1, requests: []) }
}
