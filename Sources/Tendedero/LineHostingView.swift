import AppKit
import SwiftUI
import Combine

/// Keep ordinary card/drop routing, with one bounded exception for the red
/// rope control when a swinging card overlaps its painted curve.
@MainActor final class LineHostingView: NSHostingView<LineView> {
    private var privacyObserver: AnyCancellable?
    init(line: Line) {
        super.init(rootView: LineView(line: line)); sizingOptions = []
        line.onPrivacyHide = { [weak self] in
            guard let self else { return }
            // SwiftUI may retain a disappearing host during its transition.
            for card in self.cardViews { card.isHidden = true; card.clearAccessibilityContent() }
            // Replace and lay out the root synchronously: no deferred SwiftUI
            // transition may keep sensitive pixels, while the rope menu survives.
            self.rootView = LineView(line: self.rootView.line)
            self.layoutSubtreeIfNeeded()
            self.displayIfNeeded()
            (self.window as? LinePanel)?.endKeyboardBrowsing()
        }
        privacyObserver = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak self] hidden in
            guard let self, !hidden else { return }
            for card in self.cardViews { card.isHidden = false }
        }
        if line.snapshot.privacyHidden { line.onPrivacyHide() }
    }
    var cardViews: [GrabView] {
        func collect(_ view: NSView) -> [GrabView] { (view as? GrabView).map { [$0] } ?? view.subviews.flatMap(collect) }
        return collect(self)
    }
    override func accessibilityChildren() -> [Any]? {
        guard rootView.line.revealed, !rootView.line.snapshot.privacyHidden else { return [] }
        return super.accessibilityChildren()
    }
    override var acceptsFirstResponder: Bool { true }
    func beginKeyboardBrowsing() {
        rootView.line.selectForKeyboard(step: 0)
        announceKeyboardSelection()
    }
    private func announceKeyboardSelection() {
        // Selection may materialize a new host after scrolling a large shelf.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.rootView.line.snapshot.privacyHidden,
                  let id = self.rootView.line.keyboardID else { return }
            self.layoutSubtreeIfNeeded()
            if let card = self.cardViews.first(where: { $0.materialID == id }) {
                NSAccessibility.post(element: card, notification: .focusedUIElementChanged)
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        guard let panel = window as? LinePanel, panel.isKeyboardBrowsing,
              !rootView.line.snapshot.privacyHidden else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 53: cancelOperation(nil)
        case 123, 126: rootView.line.selectForKeyboard(step: -1); announceKeyboardSelection()
        case 124, 125: rootView.line.selectForKeyboard(step: 1); announceKeyboardSelection()
        case 36, 76:
            _ = selectedCard?.accessibilityPerformPress()
        case 110: _ = selectedCard?.accessibilityPerformShowMenu()
        case 109 where event.modifierFlags.contains(.shift): _ = selectedCard?.accessibilityPerformShowMenu()
        default: super.keyDown(with: event)
        }
    }
    private var selectedCard: GrabView? {
        cardViews.first { $0.materialID == rootView.line.keyboardID }
    }
    override func cancelOperation(_ sender: Any?) {
        rootView.line.cancelPress?()
        (window as? LinePanel)?.endKeyboardBrowsing()
    }
    @MainActor required init(rootView: LineView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("Unavailable") }
    override func scrollWheel(with event: NSEvent) {
        let horizontal = event.scrollingDeltaX
        let delta = horizontal != 0 ? horizontal : (event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0)
        guard delta != 0 else { super.scrollWheel(with: event); return }
        rootView.line.scroll(by: -delta * (event.hasPreciseScrollingDeltas ? 1 : 40))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let ordinary = super.hitTest(point)
        let local = convert(point, from: superview)
        guard bounds.contains(local), rootView.line.acceptsClick(at: local, width: bounds.width) else { return nil }
        func receiver(_ view: NSView) -> LineDropTarget? {
            if let target = view as? LineDropTarget { return target }
            for child in view.subviews { if let target = receiver(child) { return target } }
            return nil
        }
        return receiver(self)?.settingsHit(at: local, in: self, ordinaryHit: ordinary) ?? ordinary
    }
}
