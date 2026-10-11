import AppKit

/// Shared by the native panels and the shelf's quiet paper surfaces.
enum PanelAppearance {
    static let margin: CGFloat = 24
    static let footerHeight: CGFloat = 72
    static let paper = NSColor(name: "InkpegPaper") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.14, green: 0.15, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
    }
    static let forest = NSColor(name: "InkpegForest") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.61, green: 0.73, blue: 0.63, alpha: 1)
            : NSColor(srgbRed: 0.27, green: 0.39, blue: 0.30, alpha: 1)
    }
    static let rope = NSColor(name: "InkpegRope") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.65, green: 0.66, blue: 0.59, alpha: 1)
            : NSColor(srgbRed: 0.46, green: 0.48, blue: 0.42, alpha: 1)
    }
    @MainActor static func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.backgroundColor = paper
    }
    @MainActor static func primary(_ button: NSButton) {
        button.bezelStyle = .rounded; button.controlSize = .large
        button.bezelColor = forest
        button.keyEquivalent = "\r"; button.keyEquivalentModifierMask = .command
    }
    @MainActor static func editor(_ view: NSTextView) {
        view.font = .systemFont(ofSize: 17)
        view.textColor = .labelColor; view.backgroundColor = paper
        view.textContainerInset = NSSize(width: margin, height: margin)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1.5
        view.defaultParagraphStyle = paragraph; view.typingAttributes[.paragraphStyle] = paragraph
    }
    @MainActor static func secondary(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 13); label.textColor = .secondaryLabelColor
    }
}

/// An opaque native surface also makes privacy covers independent of vibrancy.
final class PanelSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PanelAppearance.paper.setFill(); NSBezierPath(rect: dirtyRect).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
