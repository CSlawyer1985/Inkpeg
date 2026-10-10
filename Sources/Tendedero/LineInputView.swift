import AppKit
import SwiftUI
import InkpegCore

/// Draws only a piece of the existing rope; the native button supplies hover,
/// accessibility and first-click activation without taking the panel's focus.
@MainActor private final class RopeSettingsButton: NSButton {
    var ropeWidth: CGFloat = 0
    var ropeOrigin = CGPoint.zero
    var menuProvider: () -> NSMenu? = { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil); return true
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard window != nil, let menu = menuProvider() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let stroke = LineInputLayout.settingsStroke(width: ropeWidth)
        let segment = LineRopeGeometry.path(width: ropeWidth, from: stroke.lowerBound, to: stroke.upperBound)
            .applying(CGAffineTransform(translationX: -ropeOrigin.x, y: -ropeOrigin.y))
        context.addPath(segment.cgPath)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(2.4); context.setLineCap(.round); context.strokePath()
    }
}

@MainActor private final class LineInputFeedbackLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class LineDropTarget: NSView {
    var canReceive: () -> Bool = { true }
    var canOpenSettings: () -> Bool = { true }
    var canNewNote: () -> Bool = { true }
    var onReceive: ([ImportRequest]) -> Bool = { _ in false }
    var onHover: (Int) -> Void = { _ in }
    var onPaste: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onNewNote: () -> Void = {}
    var ropeMenuProvider: (() -> NSMenu)?
    var onRejected: () -> Void = {}
    var feedback = "" { didSet { feedbackLabel.stringValue = feedback; feedbackLabel.toolTip = feedback } }
    private let settingsButton = RopeSettingsButton(title: "", target: nil, action: nil)
    private let feedbackLabel = LineInputFeedbackLabel(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string, .init("public.jpeg"), .init("public.heic")])
        setAccessibilityLabel(L(.dropHint))
        settingsButton.isBordered = false
        settingsButton.setAccessibilityElement(true); settingsButton.setAccessibilityRole(.button)
        settingsButton.setAccessibilityLabel(L(.noteNew)); settingsButton.toolTip = L(.noteHint)
        settingsButton.menuProvider = { [weak self] in self?.ropeMenu() }
        settingsButton.target = self; addSubview(settingsButton)
        settingsButton.action = #selector(newNote)
        feedbackLabel.font = .systemFont(ofSize: 11)
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.alignment = .right; feedbackLabel.lineBreakMode = .byTruncatingTail
        addSubview(feedbackLabel)
        refreshControls()
    }
    required init?(coder: NSCoder) { fatalError("Unavailable") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func newNote() { if canNewNote() { onNewNote() } }
    func refreshControls() {
        settingsButton.isEnabled = canNewNote()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width + 100
        let rect = LineInputLayout.settingsRegion(width: width)
        settingsButton.frame = rect.offsetBy(dx: -50, dy: 0)
        settingsButton.ropeWidth = width; settingsButton.ropeOrigin = rect.origin
        settingsButton.needsDisplay = true
        feedbackLabel.frame = NSRect(x: 12, y: 0, width: max(0, settingsButton.frame.minX - 24), height: LineInputLayout.controlHeight)
    }
    /// A swinging card may reach the rope itself. Only that narrow painted
    /// curve takes priority; the generous upper target never steals a card.
    func settingsHit(at point: NSPoint, in host: NSView, ordinaryHit: NSView?) -> NSButton? {
        let local = settingsButton.convert(point, from: host)
        guard canOpenSettings(), settingsButton.bounds.contains(local) else { return nil }
        if ordinaryHit is GrabView {
            let x = local.x + settingsButton.ropeOrigin.x
            guard LineInputLayout.settingsStroke(width: settingsButton.ropeWidth).contains(x) else { return nil }
            let ropeY = LineRopeGeometry.y(x: x, width: settingsButton.ropeWidth) - settingsButton.ropeOrigin.y
            guard abs(local.y - ropeY) <= 3 else { return nil }
        }
        return settingsButton
    }
    private func candidateCount(_ board: NSPasteboard) -> Int {
        let imageTypes: Set<NSPasteboard.PasteboardType> = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
        let items = board.pasteboardItems ?? []
        guard items.count <= ClipboardLimits.items else { return 0 }
        let candidates = items.filter { !$0.types.contains(SystemClipboardGateway.ownType) }
        let files = candidates.filter { $0.types.contains(.fileURL) }
        if !files.isEmpty { return files.count }
        let images = candidates.filter { !Set($0.types).isDisjoint(with: imageTypes) }
        if !images.isEmpty { return images.count }
        return candidates.filter { $0.types.contains(.string) }.count
    }
    func receive(from board: NSPasteboard) -> Bool {
        defer { resetHover() }
        guard canReceive() else { return false }
        do {
            let snapshot = try SystemClipboardGateway(pasteboard: board).readSnapshot()
            guard !snapshot.isSelfProduced, !snapshot.requests.isEmpty, canReceive() else { return false }
            let requests = snapshot.requests.map { request -> ImportRequest in
                switch request {
                case .file(let url, _): return .file(url, .drop)
                case .imageData(let data, _): return .imageData(data, SourceRecord(origin: .drop))
                case .text(let text, _): return .text(text, SourceRecord(origin: .drop))
                }
            }
            return onReceive(requests)
        } catch { onRejected(); return false }
    }
    func updateHover(from board: NSPasteboard) -> NSDragOperation {
        let count = canReceive() ? candidateCount(board) : 0
        onHover(count)
        return count > 0 ? .copy : []
    }
    func resetHover() { onHover(0) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy) else { resetHover(); return [] }
        return updateHover(from: sender.draggingPasteboard)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { resetHover() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receive(from: sender.draggingPasteboard) }
    override func menu(for event: NSEvent) -> NSMenu? {
        ropeMenu()
    }
    private func ropeMenu() -> NSMenu {
        if let ropeMenuProvider { return ropeMenuProvider() }
        let menu = NSMenu(), item = ClosureMenuItem(L(.pasteInput)) { [weak self] in self?.onPaste() }
        let note = ClosureMenuItem(L(.noteNew)) { [weak self] in self?.onNewNote() }
        note.isEnabled = canNewNote(); menu.addItem(note)
        item.isEnabled = canReceive(); menu.addItem(item)
        let settings = ClosureMenuItem(L(.intakeSettings)) { [weak self] in self?.onOpenSettings() }
        settings.isEnabled = canOpenSettings(); settings.keyEquivalent = ","; menu.addItem(settings); return menu
    }
}
enum LineInputLayout {
    static let controlHeight: CGFloat = 24
    static func region(width: CGFloat) -> CGRect { CGRect(x: 50, y: 0, width: max(0, width - 100), height: 64) }
    static func settingsStroke(width: CGFloat) -> ClosedRange<CGFloat> {
        let center = settingsRegion(width: width).midX
        return (center - 17)...(center + 17)
    }
    static func settingsRegion(width: CGFloat) -> CGRect {
        let center = width * 0.6180339887498949, half: CGFloat = 34
        let left = LineRopeGeometry.y(x: center - half, width: width)
        let right = LineRopeGeometry.y(x: center + half, width: width)
        // Most of the transparent click target sits above the rope, before
        // the card's native grab area. Cards retain their existing priority.
        return CGRect(x: center - half, y: min(left, right) - 18,
                      width: half * 2, height: abs(left - right) + 21)
    }
}

private struct DropReceiver: NSViewRepresentable {
    @ObservedObject var line: Line
    func makeNSView(context: Context) -> LineDropTarget { let view = LineDropTarget(); configure(view); return view }
    func updateNSView(_ view: LineDropTarget, context: Context) { configure(view) }
    private func configure(_ view: LineDropTarget) {
        view.canReceive = { [weak line] in line?.revealed == true && line?.canReceiveInput == true && line?.snapshot.privacyHidden == false }
        view.canOpenSettings = { [weak line] in line?.revealed == true && line?.canOpenIntakeSettings == true }
        view.canNewNote = { [weak line] in line?.revealed == true && line?.canOpenIntakeSettings == true && line?.snapshot.privacyHidden == false }
        view.onReceive = { [weak line] in line?.onReceiveInput($0) ?? false }
        view.onHover = { [weak line] in line?.dropCount = $0 }
        view.onPaste = { [weak line] in line?.onPasteInput() }
        view.onOpenSettings = { [weak line] in line?.onOpenIntakeSettings() }
        view.onNewNote = { [weak line] in line?.onNewNote() }
        view.ropeMenuProvider = line.onRopeMenuProvider
        view.onRejected = { [weak line] in line?.onError(StoreError.invalidSource) }
        view.feedback = line.dropCount > 0 ? "" : line.inputFeedback
        view.refreshControls()
    }
}
struct LineInputView: View {
    @ObservedObject var line: Line
    var body: some View {
        ZStack(alignment: .trailing) {
            if line.dropCount > 0 {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .allowsHitTesting(false)
                Text(L(.dropReady).replacingOccurrences(of: "%d", with: String(line.dropCount)))
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            DropReceiver(line: line)
        }
    }
}
