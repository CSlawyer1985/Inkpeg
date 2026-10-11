import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones. Only explicit keyboard browsing takes focus; clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    var onAccessibilityReveal: () -> Void = {}
    private(set) var isKeyboardBrowsing = false
    private var restoreFocus: (() -> Void)?
    private var eventMonitors: [Any] = []
    func beginKeyboardBrowsing(restoringFocus: (() -> Void)? = nil) {
        guard let host = contentView as? LineHostingView, host.rootView.line.revealed,
              !host.rootView.line.snapshot.privacyHidden else { return }
        if !isKeyboardBrowsing {
            let previousApp = NSWorkspace.shared.frontmostApplication
            let previousWindow = NSApp.keyWindow
            let previousResponder = previousWindow?.firstResponder
            restoreFocus = restoringFocus ?? { [weak previousWindow, weak previousResponder] in
                if let previousWindow {
                    previousWindow.makeKeyAndOrderFront(nil)
                    if let previousResponder { previousWindow.makeFirstResponder(previousResponder) }
                }
                if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp?.activate() }
            }
        }
        isKeyboardBrowsing = true
        makeKeyAndOrderFront(nil)
        makeFirstResponder(host)
        host.beginKeyboardBrowsing()
    }
    func endKeyboardBrowsing() {
        guard isKeyboardBrowsing else { return }
        isKeyboardBrowsing = false
        (contentView as? LineHostingView)?.rootView.line.keyboardID = nil
        resignKey()
        let restore = restoreFocus; restoreFocus = nil; restore?()
    }
    func updateMousePassThrough(at screenPoint: NSPoint) {
        guard !GrabView.isDragging, let host = contentView as? LineHostingView else { return }
        // Keep a mouse-down reservation through provider preparation.
        guard host.rootView.line.pressedID == nil else { return }
        let local = convertPoint(fromScreen: screenPoint)
        ignoresMouseEvents = !host.rootView.line.acceptsClick(at: CGPoint(x: local.x, y: frame.height - local.y), width: frame.width)
    }
    private func watchPassThroughEvents() {
        // Only pointer movement updates the click gate. A global wheel monitor
        // cannot consume events: observing wheels over gaps would scroll both
        // the shelf and the app beneath it. Gaps belong to that app; cards and
        // controls continue to route horizontal wheels through the host.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough(at: NSEvent.mouseLocation) }
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.updateMousePassThrough(at: NSEvent.mouseLocation)
            return event
        }) { eventMonitors.append(monitor) }
    }
    override func close() {
        endKeyboardBrowsing()
        eventMonitors.forEach(NSEvent.removeMonitor); eventMonitors.removeAll()
        super.close()
    }
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space except full screen ones: a video or a presentation in full
        // screen should never get a clothesline across the top.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
        watchPassThroughEvents()
    }

    override var canBecomeKey: Bool { isKeyboardBrowsing }
    override var canBecomeMain: Bool { false }

    // Raising the transparent, tucked-away window must expose its contents to
    // accessibility clients. It keeps the same nonactivating focus behavior.
    override func accessibilityPerformRaise() -> Bool {
        onAccessibilityReveal()
        return true
    }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
