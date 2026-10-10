import AppKit
import SwiftUI

/// Keep ordinary card/drop routing, with one bounded exception for the red
/// rope control when a swinging card overlaps its painted curve.
@MainActor final class LineHostingView: NSHostingView<LineView> {
    init(line: Line) { super.init(rootView: LineView(line: line)); sizingOptions = [] }
    @MainActor required init(rootView: LineView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("Unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let ordinary = super.hitTest(point)
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return ordinary }
        func receiver(_ view: NSView) -> LineDropTarget? {
            if let target = view as? LineDropTarget { return target }
            for child in view.subviews { if let target = receiver(child) { return target } }
            return nil
        }
        return receiver(self)?.settingsHit(at: local, in: self, ordinaryHit: ordinary) ?? ordinary
    }
}
