import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class FullScreenCapabilityTests: XCTestCase {
    @MainActor private final class Fixture {
        let line: Line
        let panel: LinePanel
        let app: AppDelegate
        private final class Reading { var value: FullScreen.State; init(_ value: FullScreen.State) { self.value = value } }
        private let reading: Reading
        init(_ state: FullScreen.State) {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-capability-" + UUID().uuidString)
            reading = Reading(state)
            line = Line(store: MaterialStore(root: root))
            panel = LinePanel(content: LineHostingView(line: line))
            let reading = reading
            app = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root), line: line, fullScreenState: { _ in reading.value })
            app.setUpPresentationPanel(panel)
        }
        func change(_ state: FullScreen.State) { reading.value = state }
        func add() async throws -> (UUID, WorkspaceSnapshot) {
            let imported = try await line.store.importMaterial(.text("SYNTHETIC capability material", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
            await line.render(imported.snapshot)
            return (try XCTUnwrap(imported.snapshot.materials.last?.id), imported.snapshot)
        }
        func close() { app.stopMouseTracking(); panel.orderOut(nil); panel.close() }
    }

    @MainActor func testUnknownNewMaterialDoesNotAutomaticallyPresent() async throws {
        let f = Fixture(.unknown); defer { f.close() }
        _ = try await f.add(); f.app.itemsChanged()
        XCTAssertFalse(f.app.isPresent, "Unknown Spaces capability must not be treated as desktop")
        XCTAssertFalse(f.line.revealed)
    }

    @MainActor func testUnknownCaptureAndReplacementDoNotAutomaticallyReveal() async throws {
        let f = Fixture(.unknown); defer { f.close() }
        let (id, snapshot) = try await f.add()
        await f.app.presentCapture(id, area: NSRect(x: 0, y: 0, width: 100, height: 100), snapshot: snapshot)
        XCTAssertFalse(f.app.isPresent); XCTAssertFalse(f.line.revealed)
        XCTAssertTrue(f.line.items.allSatisfy { !$0.flying }, "Unknown capability must not leave a hidden flight placeholder")
        f.app.showLine(); XCTAssertTrue(f.line.revealed)
        f.app.toggle(); f.app.refresh()
        await f.app.presentCapture(id, area: nil, snapshot: snapshot)
        XCTAssertFalse(f.app.isPresent); XCTAssertFalse(f.line.revealed, "A same-count capture must respect manual hide")
    }

    @MainActor func testUnknownMouseEntryDoesNotRevealAfterManualHide() async throws {
        let f = Fixture(.unknown); defer { f.close() }
        _ = try await f.add(); f.app.showLine(); f.app.toggle()
        let screen = try XCTUnwrap(f.panel.screen)
        let band = AppDelegate.menuBarBand(of: screen), mouse = NSPoint(x: band.midX, y: band.midY)
        let now = Date(); f.app.tick(mouse: mouse, now: now); f.app.tick(mouse: mouse, now: now.addingTimeInterval(1))
        XCTAssertFalse(f.line.revealed); XCTAssertFalse(f.app.isPresent)
    }

    @MainActor func testUnknownManualAndAccessibilityShowSurviveRefreshThenHide() async throws {
        let f = Fixture(.unknown); defer { f.close() }
        _ = try await f.add()
        for accessibility in [false, true] {
            if accessibility { f.panel.onAccessibilityReveal() } else { f.app.showLine() }; f.app.refresh(); f.app.refresh()
            XCTAssertTrue(f.app.isPresent); XCTAssertTrue(f.line.revealed)
            f.app.toggle(); f.app.refresh()
            XCTAssertFalse(f.app.isPresent); XCTAssertFalse(f.line.revealed)
        }
    }

    @MainActor func testKnownDesktopAutoRevealAndFullScreenBlockingRemain() async throws {
        let f = Fixture(.desktop); defer { f.close() }
        _ = try await f.add(); f.app.itemsChanged()
        XCTAssertTrue(f.app.isPresent); XCTAssertTrue(f.line.revealed)
        f.change(.fullScreen); f.app.refresh()
        XCTAssertFalse(f.app.isPresent); XCTAssertFalse(f.line.revealed)
        f.app.showLine(); XCTAssertFalse(f.app.isPresent); XCTAssertFalse(f.line.revealed)
        f.change(.desktop); f.app.refresh()
        XCTAssertTrue(f.app.isPresent)
    }
}

extension FullScreenCapabilityTests {
    private func display(_ id: String, _ type: Any) -> [String: Any] {
        ["Display Identifier": id, "Current Space": ["type": type]]
    }

    func testSingleDisplayAndSharedSpacesKeepTheirKnownContract() {
        XCTAssertEqual(FullScreen.parse([display("Main", 0)], displayIdentifier: nil), .desktop)
        XCTAssertEqual(FullScreen.parse([display("Main", 4)], displayIdentifier: "external"), .fullScreen)
        XCTAssertEqual(FullScreen.parse([display("Main", 0)], displayIdentifier: "external"), .desktop)
    }

    func testMultipleDisplaysUseOnlyTheRequestedDisplay() {
        let data = [display("desktop-screen", 0), display("fullscreen-screen", 4)]
        XCTAssertEqual(FullScreen.parse(data, displayIdentifier: "desktop-screen"), .desktop)
        XCTAssertEqual(FullScreen.parse(data, displayIdentifier: "fullscreen-screen"), .fullScreen)
        XCTAssertEqual(FullScreen.parse(data, displayIdentifier: "missing"), .unknown)
        XCTAssertEqual(FullScreen.parse(data, displayIdentifier: nil), .unknown)
        XCTAssertEqual(FullScreen.parse([display("same", 0), display("same", 4)], displayIdentifier: "same"), .unknown)
    }

    func testMalformedNullEmptyAndUnrecognizedSpaceTypesStayUnknown() {
        let malformed: [Any?] = [nil, [], "invalid", [1], [["Current Space": "invalid"]],
                                 [["Current Space": [:]]], [display("Main", "4")],
                                 [display("Main", true)], [display("Main", 4.5)], [display("Main", 99)]]
        for data in malformed { XCTAssertEqual(FullScreen.parse(data, displayIdentifier: "Main"), .unknown) }
    }

    func testMissingEitherPrivateSymbolIsUnknownWithoutCallingTheOther() {
        for missing in ["CGSMainConnectionID", "CGSCopyManagedDisplaySpaces"] {
            let adapter = FullScreen.Capability(resolveSymbol: { name in
                if name == missing { return nil }
                // Deliberately uncallable: a partial pair must never be invoked.
                return UnsafeMutableRawPointer(bitPattern: 1)
            })
            XCTAssertEqual(adapter.state(displayIdentifier: "Main"), .unknown)
        }
    }

    func testDynamicCapabilityActuallyInvokesAvailableSymbolsAndHandlesNull() {
        let main: @convention(c) () -> Int32 = { 42 }
        let copy: @convention(c) (Int32) -> Unmanaged<CFTypeRef>? = { connection in
            guard connection == 42 else { return nil }
            return .passRetained([["Current Space": ["type": 4]]] as NSArray)
        }
        let null: @convention(c) (Int32) -> Unmanaged<CFTypeRef>? = { _ in nil }
        for (function, expected) in [(copy, FullScreen.State.fullScreen), (null, .unknown)] {
            let adapter = FullScreen.Capability(resolveSymbol: { name in
                name == "CGSMainConnectionID" ? unsafeBitCast(main, to: UnsafeMutableRawPointer.self) : unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
            })
            XCTAssertEqual(adapter.state(displayIdentifier: nil), expected)
        }
    }

    @MainActor func testLosingCapabilitySuppressesAutomaticRevealButKeepsManualControl() async throws {
        let f = Fixture(.desktop); defer { f.close() }
        _ = try await f.add(); f.app.itemsChanged(); XCTAssertTrue(f.line.revealed)
        f.change(.unknown)
        f.app.tick(mouse: NSPoint(x: 20, y: 20))
        XCTAssertFalse(f.app.isPresent, "Polling must dismiss prior automatic presentation when capability becomes unknown")
        f.app.refresh(); XCTAssertFalse(f.app.isPresent)
        f.app.toggle(); f.app.refresh(); XCTAssertTrue(f.line.revealed)
        let screen = try XCTUnwrap(f.panel.screen)
        let outside = NSPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20), now = Date()
        f.app.tick(mouse: outside, now: now); f.app.tick(mouse: outside, now: now.addingTimeInterval(3))
        XCTAssertTrue(f.line.revealed, "Unknown fallback stays under manual control")
        f.app.toggle(); f.app.refresh(); XCTAssertFalse(f.app.isPresent)
        _ = try await f.add(); f.app.itemsChanged(); XCTAssertFalse(f.line.revealed)
        f.change(.desktop); f.app.refresh(); XCTAssertTrue(f.app.isPresent)
    }

    @MainActor func testKnownDesktopMouseAndCaptureStillRevealAndPrivacyStillBlocksCapture() async throws {
        let f = Fixture(.desktop); defer { f.close() }
        let (id, snapshot) = try await f.add()
        await f.app.presentCapture(id, area: nil, snapshot: snapshot); XCTAssertTrue(f.line.revealed)
        f.app.toggle()
        let screen = try XCTUnwrap(f.panel.screen), band = AppDelegate.menuBarBand(of: screen)
        let mouse = NSPoint(x: band.midX, y: band.midY), now = Date()
        f.app.tick(mouse: mouse, now: now); f.app.tick(mouse: mouse, now: now.addingTimeInterval(1))
        XCTAssertTrue(f.line.revealed)
        f.app.toggle()
        var hidden = snapshot; hidden.privacyHidden = true
        await f.app.presentCapture(id, area: nil, snapshot: hidden)
        XCTAssertFalse(f.line.revealed); XCTAssertTrue(f.line.items.isEmpty)
    }
}
