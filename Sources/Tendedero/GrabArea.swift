import AppKit
import SwiftUI

/// Click copies; long press edits a draft; drag promises a copy and leaves the card.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let note = line.snapshot.materials.first(where: { $0.id == id })?.source.origin == .note
        view.setAccessibilityLabel(L(note ? .noteContinue : .copy))
        view.setAccessibilityHelp(L(.open) + " · " + L(.markup))
        view.promise = line.snapshot.privacyHidden ? nil : CopyOutProvider(store: line.store, id: id, versionID: item.versionID, suffix: item.url.pathExtension) { [weak line] in line?.snapshot.privacyHidden == false }.provider()
        view.dragImage = item.thumb
        view.singleClickImmediately = note
        view.onClick = { if note { line.onOpenNote(id) } else { line.copy(id) } }
        view.onDoubleClick = { if note { line.onOpenNote(id) } else { line.open(id) } }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil

        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { if note { line.onOpenNote(id) } else if item.kind == .image || item.kind == .text { line.markup(id) } }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L(.copy)) { line.copy(id) })
            if item.kind == .text && !note { menu.addItem(ClosureMenuItem(L(.copyWithSource)) { line.onCopySource(id) }) }
            menu.addItem(ClosureMenuItem(L(.materialDetails)) { line.open(id) })
            if note { menu.addItem(ClosureMenuItem(L(.noteContinue)) { line.onOpenNote(id) }) }
            else if item.kind == .image || item.kind == .text { menu.addItem(ClosureMenuItem(L(item.kind == .text ? .editText : .markup)) { line.markup(id) }) }
            menu.addItem(ClosureMenuItem(L(.showInFinder)) { line.reveal(id) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L(.takeDown)) { line.drop(id) })
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard window != nil else { return false }
        menuProvider().popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    var promise: NSFilePromiseProvider?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var singleClickImmediately = false
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var clickWork: DispatchWorkItem?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            clickWork?.cancel(); endPress()
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let promise else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        clickWork?.cancel(); endPress()

        let item = NSDraggingItem(pasteboardWriter: promise)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 {
            if singleClickImmediately { onClick() }
            else {
                let work = DispatchWorkItem { [weak self] in self?.onClick() }
                clickWork?.cancel(); clickWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false; startedDrag = false; downPoint = nil
        onDragEnd()
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
