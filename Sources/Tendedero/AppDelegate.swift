import AppKit
import Carbon
import Combine
import InkpegCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let environment: AppEnvironment
    init(environment: AppEnvironment) {
        self.environment = environment
        self.line = Line(store: MaterialStore(root: environment.dataRoot))
        super.init()
    }
    private let line: Line
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private var capture: CaptureFolderCoordinator?
    private var clipboard: ClipboardImportService?
    private var clipboardTimer: Timer?
    private var intakeSettings: IntakeSettingsController?
    private var lineIntake: LineIntakeController?
    private var actions: MaterialActions?
    private var recovery: WorkflowRecoveryController?
    private var textEditor: TextEditorController?
    private var noteEditor: NoteEditorController?
    private var detail: MaterialDetailController?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: L(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(title: L(.editMenu), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L(.editMenu))
        edit.addItem(withTitle: L(.editUndo), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L(.editRedo), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L(.editCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L(.editCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L(.editPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L(.editSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let close = appMenu.addItem(withTitle: L(.editClose), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = .command
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = LineHostingView(line: line)
        panel = LinePanel(content: host)
        panel.onAccessibilityReveal = { [weak self] in self?.showLine() }
        panel.placeOnScreen()
        updateCapacity()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.line.load()
                self.activateMaterialWorkflow()
            }
            catch { self.presentRecovery(error) }
        }

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        setUpStatusItem()
        watchMenuBarClicks()

        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }
    }

    private func activateMaterialWorkflow() {
        capture?.stop()
        clipboard?.stop()
        clipboardTimer?.invalidate()
        let capture = CaptureFolderCoordinator(store: self.line.store)
        capture.capacity = { [weak self] in self?.line.maxItems ?? 8 }
        capture.onSnapshot = { [weak self] in await self?.line.render($0) }
        capture.onError = { [weak self] in self?.presentCaptureError($0) }
        capture.onStatusChanged = { [weak self, weak capture] in
            guard capture != nil else { return }
            self?.refreshIntakeStatus()
        }
        capture.onImported = { [weak self] id, area, snapshot in await self?.presentCapture(id, area: area, snapshot: snapshot) }
        self.capture = capture
        let actions = MaterialActions(line: self.line, root: self.environment.dataRoot)
        actions.onError = { [weak self] in self?.presentActionError($0) }
        self.actions = actions
        let editor = TextEditorController(line: line)
        editor.onError = { [weak self] in self?.presentActionError($0) }
        textEditor = editor
        let notes = NoteEditorController(line: line)
        notes.onError = { [weak self] in self?.presentActionError($0) }
        notes.onHung = { [weak self] in self?.showLine() }
        noteEditor = notes
        line.onNewNote = { [weak self] in Task { do { try await self?.noteEditor?.openNew() } catch { self?.presentActionError(error) } } }
        line.onOpenNote = { [weak self] id in Task { do { try await self?.noteEditor?.open(id) } catch { self?.presentActionError(error) } } }
        line.onRopeMenuProvider = { [weak self] in self?.makeRopeMenu() ?? NSMenu() }
        let detail = MaterialDetailController(line: line, actions: actions, editor: editor)
        detail.onError = { [weak self] in self?.presentActionError($0) }
        self.detail = detail
        let recovery = WorkflowRecoveryController(line: line, actions: actions)
        recovery.onError = { [weak self] in self?.presentActionError($0) }
        self.recovery = recovery
        recovery.onResumeText = { [weak self] session in Task { do { try await self?.textEditor?.resume(session) } catch { self?.presentActionError(error) } } }
        recovery.onResumeNote = { [weak self] draft in Task { do { try await self?.noteEditor?.resume(draft) } catch { self?.presentActionError(error) } } }
        Task { await recovery.refresh(showIfNeeded: true) }
        self.line.onCopy = { [weak self] id in Task { do { try await self?.actions?.copy(id) } catch { self?.presentActionError(error) } } }
        self.line.onOpen = { [weak self] id in Task { do { try await self?.detail?.open(id) } catch { self?.presentActionError(error) } } }
        self.line.onCopySource = { [weak self] id in Task { do { try await self?.actions?.copy(id, includeSource: true) } catch { self?.presentActionError(error) } } }
        self.line.onReveal = { [weak self] id in Task { do { try await self?.actions?.reveal(id) } catch { self?.presentActionError(error) } } }
        self.line.onMarkup = { [weak self] id in Task {
            guard let self else { return }
            do {
                if self.line.snapshot.materials.first(where: { $0.id == id })?.kind == .text { try await self.textEditor?.open(id) }
                else { try await self.actions?.markup(id) }
            } catch { self.presentActionError(error) }
        } }
        self.line.onCommand = { [weak self] command in Task {
            guard let self else { return }
            do {
                _ = try await self.line.store.apply(command, visibleCapacity: self.line.maxItems)
                switch command {
                case .takeDown(let id): self.line.animateTakeDown(id)
                case .takeDownUnpinned(let matterID):
                    for item in self.line.snapshot.materials where item.matterID == matterID && item.status == .hanging && !item.pinned { self.line.animateTakeDown(item.id) }
                default: break
                }
                if !self.line.snapshot.privacyHidden && self.line.soundOn { NSSound(named: "Pop")?.play() }
                try await Task.sleep(nanoseconds: 100_000_000)
                await self.line.render(try await self.line.store.load())
            }
            catch { self.presentActionError(error) }
        } }
        self.line.onError = { [weak self] in self?.presentActionError($0) }
        capture.restore(self.line.snapshot)
        let clipboard = ClipboardImportService(gateway: SystemClipboardGateway(), store: line.store,
            capacity: { [weak self] in self?.line.maxItems ?? 8 }, canRead: { [weak self] in self?.line.snapshot.privacyHidden == false })
        clipboard.onSnapshot = { [weak self] in await self?.line.render($0) }
        clipboard.onImported = { [weak self] id, snapshot in
            self?.lineIntake?.imported()
            await self?.presentCapture(id, area: nil, snapshot: snapshot)
        }
        clipboard.onStateChanged = { [weak self] in self?.refreshIntakeStatus() }
        self.clipboard = clipboard
        self.lineIntake = LineIntakeController(line: line, service: clipboard)
        self.intakeSettings = IntakeSettingsController(service: clipboard, capture: capture, libraryURL: environment.dataRoot, store: line.store, line: line)
        self.line.canOpenIntakeSettings = true
        self.line.onOpenIntakeSettings = { [weak self] in self?.intakeSettings?.present() }
        Task { await clipboard.start() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.clipboard?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private func refreshIntakeStatus() {
        line.canReceiveInput = clipboard?.canReceiveManual == true
        lineIntake?.refresh()
        intakeSettings?.model.refresh()
        let clipboardState = clipboard.map { L($0.state.messageKey) } ?? ""
        statusItem.button?.toolTip = "文夹 · " + L(capture?.status ?? .capturePaused) + " · " + clipboardState
        let warning = capture?.hasWarning == true || [.pending, .changedFile, .unavailable, .rejected].contains(clipboard?.state)
        statusItem.button?.title = warning ? "!" : ""
    }

    private func presentCapture(_ id: UUID, area: CGRect?, snapshot: WorkspaceSnapshot) async {
        guard !snapshot.privacyHidden else { await line.render(snapshot); return }
        let screen = area.flatMap { area in
            NSScreen.screens.filter { $0.frame.intersects(area) }.max { left, right in
                let a = left.frame.intersection(area), b = right.frame.intersection(area)
                return a.width * a.height < b.width * b.height
            }
        } ?? LinePanel.screenUnderPointer()
        pendingScreen = screen; panel.placeOnScreen(screen); updateCapacity()
        let flies = area != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        await line.render(snapshot, flightID: flies ? id : nil)
        wanted = true; refresh(); reveal(peekFor: 2.5) // Also preview replacements when the shelf count is unchanged.
        if line.soundOn { NSSound(named: "Pop")?.play() }
        if let area, flies { DispatchQueue.main.async { self.fly(id, from: area) } }
    }

    private func presentCaptureError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = L(.captureUnavailable)
        alert.addButton(withTitle: L(.chooseCaptureFolder)); alert.addButton(withTitle: L(.cancel))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { capture?.chooseFolder() }
    }

    private func presentActionError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = L(.actionFailed)
        alert.addButton(withTitle: L(.cancel)); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    private func presentRecovery(_ error: Error, allowRecovery: Bool = true) {
        let alert = NSAlert()
        alert.messageText = L(.recoveryTitle)
        alert.informativeText = L(.recoveryMessage)
        let canRecover = allowRecovery && [.recoveryRequired, .invalidSnapshot].contains(error as? StoreError)
        if canRecover { alert.addButton(withTitle: L(.recoveryPrevious)) }
        alert.addButton(withTitle: L(.revealWorkspace))
        alert.addButton(withTitle: L(.quit))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if canRecover && response == .alertFirstButtonReturn {
            Task {
                do {
                    await line.render(try await line.store.restorePreviousSnapshot())
                    activateMaterialWorkflow()
                }
                catch { presentRecovery(error, allowRecovery: false) }
            }
        } else if response == (canRecover ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            NSWorkspace.shared.activateFileViewerSelecting([environment.dataRoot])
        } else { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination(markup: .shared, clipboard: clipboard, textEditor: textEditor, noteEditor: noteEditor, respond: { $0.runModal() })
    }

    // Keep the existing draft guard and clipboard decision in one testable UI boundary.
    func requestTermination(markup: Markup, clipboard: ClipboardImportService?, textEditor: TextEditorController? = nil, noteEditor: NoteEditorController? = nil, respond: (NSAlert) -> NSApplication.ModalResponse) -> NSApplication.TerminateReply {
        if noteEditor?.hasUnsavedInput == true || noteEditor?.isBusy == true {
            let alert = NSAlert(); alert.messageText = L(.noteSavingQuit); alert.addButton(withTitle: L(.cancel))
            _ = respond(alert); return .terminateCancel
        }
        if textEditor?.isEditing == true {
            let alert = NSAlert(); alert.messageText = L(.textEditingTitle); alert.addButton(withTitle: L(.cancel))
            _ = respond(alert); return .terminateCancel
        }
        if markup.isEditing {
            let canRetry = markup.canRetrySaving
            let alert = NSAlert(); alert.messageText = L(markup.hasPendingResult ? .markupSaveRetained : .markupInProgress)
            if canRetry { alert.addButton(withTitle: L(.retryMarkup)) }
            alert.addButton(withTitle: L(.cancel))
            if respond(alert) == .alertFirstButtonReturn && canRetry { Task { await markup.retrySaving() } }
            return .terminateCancel
        }
        if clipboard?.hasUnsavedInput == true {
            let alert = NSAlert(); alert.messageText = L(.clipboardPendingQuit)
            alert.informativeText = L(.discardClipboardMessage)
            alert.addButton(withTitle: L(.cancel)); alert.addButton(withTitle: L(.retryClipboard)); alert.addButton(withTitle: L(.quitDiscardingClipboard))
            let response = respond(alert)
            if response == .alertSecondButtonReturn { Task { await clipboard?.retryPending() } }
            if response == .alertThirdButtonReturn, clipboard?.discardPending() == true { clipboard?.stop(); return .terminateNow }
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { capture?.stop(); clipboard?.stop(); clipboardTimer?.invalidate() }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount && !line.snapshot.privacyHidden {
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func fly(_ id: UUID, from: CGRect) {
        guard !line.snapshot.privacyHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard !line.snapshot.privacyHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            showLine()
        }
    }

    private func showLine() {
        keepOpen = true
        wanted = true
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        reveal(pinned: true)
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreen.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || line.dropCount > 0 || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a card or the input strip. Elsewhere, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
            || line.inputRegion(width: panel.frame.width).contains(flipped)
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "文夹")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L(.hideLine)
                                                 : L(.showLine)) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L(.takeDownAll)) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let note = ClosureMenuItem(L(.noteNew)) { [weak self] in self?.line.onNewNote() }
        note.isEnabled = noteEditor != nil && !line.snapshot.privacyHidden; menu.addItem(note)
        let paste = ClosureMenuItem(L(.pasteInput)) { [weak self] in self?.line.onPasteInput() }
        paste.isEnabled = clipboard?.canReceiveManual == true
        menu.addItem(paste)
        let files = ClosureMenuItem(L(.importFiles), key: "o") { [weak self] in self?.chooseFiles() }
        files.isEnabled = clipboard?.canReceiveManual == true && !line.snapshot.privacyHidden
        menu.addItem(files)
        let settings = ClosureMenuItem(L(.intakeSettings)) { [weak self] in self?.intakeSettings?.present() }
        settings.keyEquivalent = ","
        settings.isEnabled = intakeSettings != nil
        menu.addItem(settings)
        menu.addItem(.separator())

        let clipboardState = NSMenuItem(title: L(clipboard?.state.messageKey ?? .clipboardPaused), action: nil, keyEquivalent: "")
        clipboardState.isEnabled = false
        menu.addItem(clipboardState)
        let clipboardToggle = ClosureMenuItem(L(clipboard?.isEnabled == false ? .resumeClipboard : .pauseClipboard)) { [weak self] in
            guard let clipboard = self?.clipboard else { return }
            Task { await clipboard.setEnabled(!clipboard.isEnabled) }
        }
        clipboardToggle.isEnabled = clipboard != nil && clipboard?.isSavingPreferences == false
        menu.addItem(clipboardToggle)
        if let clipboard, clipboard.pendingCount > 0 || clipboard.state == .rejected {
            menu.addItem(ClosureMenuItem(L(.retryClipboard) + " (\(clipboard.pendingCount))") { Task { await clipboard.retryPending() } })
            if clipboard.pendingCount > 0 {
                let discard = ClosureMenuItem(L(.discardClipboard)) { [weak self] in self?.confirmDiscardClipboard() }
                discard.isEnabled = clipboard.canDiscardPending
                menu.addItem(discard)
            }
        }
        menu.addItem(.separator())

        if let capture {
            let state = NSMenuItem(title: L(capture.status), action: nil, keyEquivalent: "")
            state.isEnabled = false; menu.addItem(state)
        }
        menu.addItem(ClosureMenuItem(L(.chooseCaptureFolder)) { [weak self] in self?.capture?.chooseFolder() })
        menu.addItem(ClosureMenuItem(L(capture?.isEnabled == true ? .pauseCapture : .resumeCapture)) { [weak self] in self?.capture?.toggleEnabled() })
        if let capture, capture.pendingCount > 0 {
            menu.addItem(ClosureMenuItem(L(.retryCapture) + " (\(capture.pendingCount))") { capture.retryPending() })
        }
        if Markup.shared.canRetrySaving {
            menu.addItem(ClosureMenuItem(L(.retryMarkup)) { Task { await Markup.shared.retrySaving() } })
        }
        menu.addItem(ClosureMenuItem(L(.reviewPendingTitle)) { [weak self] in Task { await self?.recovery?.show() } })
        menu.addItem(.separator())

        let sound = ClosureMenuItem(L(.sounds)) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L(.quit), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private func chooseFiles() {
        guard line.canReceiveInput, !line.snapshot.privacyHidden else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { _ = line.onReceiveInput(panel.urls.map { .file($0, .fileSelection) }) }
    }
    private func makeRopeMenu() -> NSMenu {
        let menu = NSMenu()
        let note = ClosureMenuItem(L(.noteNew)) { [weak self] in self?.line.onNewNote() }
        note.isEnabled = noteEditor != nil && !line.snapshot.privacyHidden; menu.addItem(note)
        let paste = ClosureMenuItem(L(.pasteInput)) { [weak self] in self?.line.onPasteInput() }
        paste.isEnabled = clipboard?.canReceiveManual == true; menu.addItem(paste)
        let files = ClosureMenuItem(L(.importFiles)) { [weak self] in self?.chooseFiles() }
        files.isEnabled = clipboard?.canReceiveManual == true && !line.snapshot.privacyHidden; menu.addItem(files)
        menu.addItem(.separator())
        let settings = ClosureMenuItem(L(.intakeSettings), key: ",") { [weak self] in self?.intakeSettings?.present() }
        settings.isEnabled = intakeSettings != nil; menu.addItem(settings)
        menu.addItem(ClosureMenuItem(isRevealed ? L(.hideLine) : L(.showLine)) { [weak self] in self?.toggle() })
        return menu
    }
    private func confirmDiscardClipboard() {
        let alert = NSAlert(); alert.messageText = L(.discardClipboardTitle)
        alert.informativeText = L(.discardClipboardMessage)
        alert.addButton(withTitle: L(.keepClipboard)); alert.addButton(withTitle: L(.discardClipboard))
        if alert.runModal() == .alertSecondButtonReturn { clipboard?.discardPending() }
    }
}
