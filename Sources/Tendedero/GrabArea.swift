import AppKit
import SwiftUI
import InkpegCore

/// Click copies; long press edits a draft; drag shares a copy and leaves the card.
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

    static func dismantleNSView(_ view: GrabView, coordinator: ()) {
        view.cancelDragPreparation()
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let note = line.snapshot.materials.first(where: { $0.id == id })?.source.origin == .note
        view.materialID = id
        view.isContentAvailable = { !line.snapshot.privacyHidden && line.revealed && line.items.contains { $0.id == id && !$0.falling } }
        view.setAccessibilityElement(view.isContentAvailable())
        view.setAccessibilityLabel(view.isContentAvailable() ? line.cardAccessibilityLabel(item) : nil)
        view.isKeyboardSelected = { line.keyboardID == id && !line.snapshot.privacyHidden }
        view.setAccessibilityHelp(view.isContentAvailable() ? L(note ? .noteContinue : .copy) + " · " + L(.shelfKeyboardHelp) : nil)
        view.prepareDrag = { try await line.onPrepareDrag(item) }
        // Privacy revokes the press reservation even if the shelf is restored
        // before a suspended provider returns.
        view.canDrag = { !line.snapshot.privacyHidden && line.pressedID == id }
        view.onDragError = { line.onError($0) }
        view.dragImage = view.isContentAvailable() ? item.thumb : nil
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
        view.onPressChange = { [weak view] pressed in
            if pressed {
                line.pressedID = id
                line.cancelPress = { [weak view] in view?.cancelDragPreparation() }
            } else if line.pressedID == id {
                line.pressedID = nil
                line.cancelPress = nil
            }
        }
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
    override func isAccessibilityFocused() -> Bool { isContentAvailable() && isKeyboardSelected() }
    var isKeyboardSelected: () -> Bool = { false }
    var materialID: UUID?
    var isContentAvailable: () -> Bool = { true }
    func clearAccessibilityContent() {
        setAccessibilityElement(false); setAccessibilityLabel(nil); setAccessibilityHelp(nil)
        dragImage = nil
    }
    override func isAccessibilityElement() -> Bool { isContentAvailable() && super.isAccessibilityElement() }
    override func accessibilityPerformPress() -> Bool { guard isContentAvailable() else { return false }; onClick(); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard window != nil, isContentAvailable() else { return false }
        menuProvider().popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    var prepareDrag: () async throws -> NSFilePromiseProvider = { throw StoreError.invalidSource }
    var canDrag: () -> Bool = { true }
    var onDragError: (Error) -> Void = { _ in }
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
    // The only system side-effect boundary; tests keep the real gesture and
    // provider lifecycle without starting a system-wide dragging session.
    var beginSession: (GrabView, [NSDraggingItem], NSEvent) -> Void = { view, items, event in
        let session = view.beginDraggingSession(with: items, event: event, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var clickWork: DispatchWorkItem?
    private var didLongPress = false
    private var dragPreparation: Task<Void, Never>?
    private var pendingDragEvent: NSEvent?
    private var preparedProvider: NSFilePromiseProvider?
    private var gestureGeneration = 0

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
        cancelDragPreparation()
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
        pendingDragEvent = nil; preparedProvider = nil
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

    func cancelDragPreparation() {
        gestureGeneration &+= 1
        dragPreparation?.cancel(); dragPreparation = nil
        downPoint = nil
        pendingDragEvent = nil; preparedProvider = nil
        endPress()
    }

    override func cancelOperation(_ sender: Any?) { cancelDragPreparation() }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, canDrag() else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        clickWork?.cancel()
        // Stop long-press actions, but retain the native host across await.
        holdTimer?.invalidate(); holdTimer = nil
        pendingDragEvent = event
        guard dragPreparation == nil else { return }
        let generation = gestureGeneration
        let prepare = prepareDrag
        dragPreparation = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == gestureGeneration {
                    dragPreparation = nil
                    endPress()
                }
            }
            do {
                let provider = try await prepare()
                try Task.checkCancellation()
                guard generation == gestureGeneration, downPoint != nil, !startedDrag,
                      window != nil, canDrag(), let latest = pendingDragEvent else { return }
                preparedProvider = provider
                startDrag(with: latest, provider: provider)
            } catch is CancellationError { }
            catch { if generation == gestureGeneration && downPoint != nil && canDrag() { onDragError(error) } }
        }
    }

    private func startDrag(with event: NSEvent, provider: NSFilePromiseProvider) {
        startedDrag = true
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        // Released where nothing accepts it: it flies back to the line.
        beginSession(self, [item], event)
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        if downPoint != nil && !startedDrag && pendingDragEvent == nil && !didLongPress && event.clickCount == 1 {
            if singleClickImmediately { onClick() }
            else {
                let work = DispatchWorkItem { [weak self] in self?.onClick() }
                clickWork?.cancel(); clickWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }
        cancelDragPreparation()
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
        finishDrag()
    }

    func finishDrag() {
        GrabView.isDragging = false; startedDrag = false; downPoint = nil
        pendingDragEvent = nil; preparedProvider = nil
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
