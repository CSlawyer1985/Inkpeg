import AppKit
import Carbon
import SwiftUI
import XCTest
import InkpegCore
@testable import Inkpeg

final class InteractionFeedbackTests: XCTestCase {
    @MainActor func testConflictAndRegistrationFailureStayFailedUntilRetryAndMenuStillOpens() throws {
        var result: OSStatus = OSStatus(eventHotKeyExistsErr)
        var attempts = 0, removed = 0, opened = 0
        let hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey, backend: .init(
            install: { _ in (noErr, { removed += 1 }) },
            register: { key, modifiers in
                XCTAssertEqual(key, kVK_ANSI_T); XCTAssertEqual(modifiers, controlKey | optionKey)
                attempts += 1; return (result, result == noErr ? {} : nil)
            })) { opened += 1 }
        XCTAssertEqual(hotKey.status, .conflict)
        let menu = NSMenu()
        ShortcutMenu.append(to: menu, hotKey: hotKey, title: "Open synthetic shelf") { opened += 1 }
        let open = try XCTUnwrap(menu.items.first as? ClosureMenuItem)
        XCTAssertTrue(open.isEnabled); XCTAssertEqual(open.keyEquivalent, "")
        if let selector = open.action { _ = open.perform(selector, with: open) }
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(menu.items.contains { $0.title == L(.shortcutConflict) })
        XCTAssertFalse(menu.items.contains { $0.title == L(.shortcutActive) })
        let retry = try XCTUnwrap(menu.items.first { $0.title == L(.shortcutRetry) } as? ClosureMenuItem)
        let retryAction = try XCTUnwrap(retry.action)
        result = -50; _ = retry.perform(retryAction, with: retry); XCTAssertEqual(hotKey.status, .failed)
        XCTAssertEqual(removed, 2, "Each failed registration must release its event handler")
        result = noErr; _ = retry.perform(retryAction, with: retry); XCTAssertEqual(hotKey.status, .registered)
        hotKey.retry(); XCTAssertEqual(attempts, 3, "Retrying success must not install another handler")
        let recovered = NSMenu()
        ShortcutMenu.append(to: recovered, hotKey: hotKey, title: "Open synthetic shelf") {}
        XCTAssertEqual(recovered.items.first?.keyEquivalent, "t")
        XCTAssertTrue(recovered.items.contains { $0.title == L(.shortcutActive) })
        XCTAssertFalse(recovered.items.contains { $0.title == L(.shortcutRetry) })
    }

    @MainActor func testHandlerFailureNeverRegistersOrDispatchesAndSuccessOwnsCleanup() {
        var registerCalls = 0, actions = 0, handlersRemoved = 0, registrationsRemoved = 0
        var callback: (() -> Void)?
        var fail = true
        var key: HotKey? = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey, backend: .init(
            install: { action in callback = action; return fail ? (-50, nil) : (noErr, { handlersRemoved += 1 }) },
            register: { _, _ in registerCalls += 1; return (noErr, { registrationsRemoved += 1 }) })) { actions += 1 }
        XCTAssertEqual(key?.status, .failed); XCTAssertEqual(registerCalls, 0)
        callback?(); XCTAssertEqual(actions, 0)
        fail = false; key?.retry(); callback?(); XCTAssertEqual(actions, 1)
        key = nil
        XCTAssertEqual(handlersRemoved, 1); XCTAssertEqual(registrationsRemoved, 1)
        callback?(); XCTAssertEqual(actions, 1, "Disposed callback must not invoke a stale owner")
    }

    func testKnownFailuresHaveDistinctActionablePrivateFeedbackInAllLocales() {
        let failures: [(Error, MessageKey, InteractionFeedback.Action)] = [
            (StoreError.budgetExceeded, .feedbackCapacity, .storage),
            (StoreError.unavailableSpace, .feedbackCapacity, .storage),
            (StoreError.sourceChanged, .feedbackSourceChanged, .chooseFiles),
            (StoreError.invalidPath, .feedbackPath, .settings),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                     userInfo: [NSLocalizedDescriptionKey: "SECRET synthetic source", NSFilePathErrorKey: "/private/synthetic-secret"]), .feedbackPermission, .settings),
            (StoreError.operationInProgress, .feedbackBusy, .wait),
            (StoreError.recoveryRequired, .feedbackRecovery, .recovery)
        ]
        for (error, message, action) in failures {
            let feedback = InteractionFeedback(error)
            XCTAssertEqual(feedback.message, message); XCTAssertEqual(feedback.action, action)
            for locale in ["en", "es", "zh-Hans"] {
                let text = Localizer(localeIdentifier: locale).string(feedback.message)
                XCTAssertNotEqual(text, message.rawValue); XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("/private/"))
                XCTAssertGreaterThan(text.count, 30)
            }
        }
    }

    @MainActor func testSecondExplicitIntakeReportsBusyAndFirstOperationCanStillSucceed() async throws {
        let line = Line(store: MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-interaction-busy-" + UUID().uuidString)))
        try await line.load()
        let board = NSPasteboard(name: .init("InkpegInteractionBusy-" + UUID().uuidString))
        let service = ClipboardImportService(gateway: SystemClipboardGateway(pasteboard: board), store: line.store)
        let controller = LineIntakeController(line: line, service: service)
        service.onImported = { _, _ in controller.imported() }
        service.onStateChanged = { controller.refresh() }
        await service.start()
        let completed = expectation(description: "First intake commits")
        service.onStateChanged = { controller.refresh(); if line.inputFeedback == L(.inputSaved) { completed.fulfill() } }
        XCTAssertTrue(controller.enqueue([.text("Synthetic first operation", SourceRecord(origin: .drop))]))
        XCTAssertFalse(controller.enqueue([.text("Synthetic blocked operation", SourceRecord(origin: .drop))]))
        XCTAssertEqual(line.inputFeedback, L(.feedbackBusy))
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(line.inputFeedback, L(.inputSaved))
        let snapshot = try await line.store.load(); XCTAssertEqual(snapshot.materials.count, 1)
    }

    @MainActor func testReduceMotionSkipsDisplacementAnimationAndKeepsRenderedFinalCardGeometry() async throws {
        XCTAssertNil(ShelfMotion.animation(reduceMotion: true, normal: .spring()))
        XCTAssertNotNil(ShelfMotion.animation(reduceMotion: false, normal: .spring()))
        let line = Line(store: MaterialStore(root: URL(fileURLWithPath: "/tmp/inkpeg-interaction-motion-" + UUID().uuidString)))
        _ = try await line.store.importMaterial(.text("Synthetic motion card", SourceRecord(origin: .drop)), into: MatterGroup.ungroupedID, visibleCapacity: 4)
        try await line.load(); line.revealed = true
        var geometry = [CGRect]()
        for reduced in [false, true] {
            let host = NSHostingView(rootView: LineView(line: line).environment(\.shelfReduceMotionOverride, reduced))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: Layout.panelHeight), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded()
            // The ordinary entry sway is deliberately underdamped; wait for
            // rest instead of comparing its transient 900 ms animation frame.
            try await Task.sleep(nanoseconds: reduced ? 200_000_000 : 6_000_000_000)
            host.layoutSubtreeIfNeeded()
            geometry.append(try XCTUnwrap(line.hitRects[line.items[0].id]))
            XCTAssertEqual(line.items.count, 1); XCTAssertTrue(line.revealed)
            window.close()
        }
        XCTAssertEqual(geometry[0].minX, geometry[1].minX, accuracy: 0.1)
        XCTAssertEqual(geometry[0].minY, geometry[1].minY, accuracy: 0.1)
        XCTAssertEqual(geometry[0].width, geometry[1].width, accuracy: 0.1)
        XCTAssertEqual(geometry[0].height, geometry[1].height, accuracy: 0.1)
    }
}
