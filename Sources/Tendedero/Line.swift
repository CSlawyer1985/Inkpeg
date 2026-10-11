import AppKit
import Combine
import InkpegCore
import os

let log = Logger(subsystem: "local.inkpeg.Inkpeg", category: "line")

struct Pegged: Identifiable, Equatable {
    let id: UUID
    let versionID: UUID
    let url: URL
    var thumb: NSImage
    var displayTitle = ""
    var previewText: String?
    var kind = MaterialKind.image
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    var flying = false
    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.versionID == b.versionID && a.url == b.url
            && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
            && a.displayTitle == b.displayTitle && a.previewText == b.previewText && a.kind == b.kind
    }
}

/// Presentation of committed records; no source-file writes or path-array store.
@MainActor
final class Line: ObservableObject {
    let store: MaterialStore
    @Published private(set) var snapshot = WorkspaceSnapshot()
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    var cancelPress: (() -> Void)?
    @Published var keyboardID: UUID?
    var onPrivacyHide: () -> Void = {}
    private(set) var privacyEpoch = 0
    @Published private(set) var privacySaving = false
    @Published private(set) var privacySaveFailed = false
    private var privacyOverride: Bool?
    private var privacyRequest = 0
    private var privacyDesired = true
    private var privacyTask: Task<Void, Never>?
    private var savedKeyboardID: UUID?
    private var savedScrollOffset: CGFloat = 0
    private var ownedModals: [ObjectIdentifier: NSWindow] = [:]
    func permitsPresentation(_ epoch: Int) -> Bool { !snapshot.privacyHidden && epoch == privacyEpoch }

    /// Cover synchronously, before an actor hop or disk write. Only an explicit,
    /// successfully persisted reveal can remove this session's privacy override.
    func setPrivacyHidden(_ hidden: Bool) {
        privacyRequest += 1
        privacyDesired = hidden
        let request = privacyRequest
        privacyOverride = true
        coverImmediately()
        privacySaving = true; privacySaveFailed = false
        let previous = privacyTask
        privacyTask = Task { [weak self] in
            await previous?.value
            guard let self, request == self.privacyRequest else { return }
            do {
                let result = try await self.store.apply(.setPrivacyHidden(hidden))
                guard request == self.privacyRequest else { return }
                self.privacyOverride = hidden
                await self.render(result)
                guard request == self.privacyRequest else { return }
                self.privacySaving = false
            } catch {
                guard request == self.privacyRequest else { return }
                self.privacySaving = false; self.privacySaveFailed = true
                self.inputFeedback = L(.privacySaveFailed)
            }
        }
    }
    func waitForPrivacyPersistence() async { await privacyTask?.value }
    func retryPrivacyPersistence() { setPrivacyHidden(privacyDesired) }
    private func coverImmediately() {
        if !snapshot.privacyHidden { savedKeyboardID = keyboardID; savedScrollOffset = scrollOffset; privacyEpoch += 1 }
        var hidden = snapshot; hidden.privacyHidden = true
        renderGeneration += 1
        snapshot = hidden
        cancelOwnedModals()
        CaptureFlight.cancelAll()
        // Revoke the gesture before the host synchronously dismantles its views;
        // dismantling must not publish a live press change inside a SwiftUI update.
        cancelPress?(); cancelPress = nil; pressedID = nil; copiedID = nil
        onPrivacyHide()
        presentations.removeAll(); arrivedIDs.removeAll()
        items = []; hitRects = [:]; scrollOffset = 0
        inputFeedback = ""
    }
    func runModal(_ window: NSWindow, operation: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        guard !snapshot.privacyHidden else { return .cancel }
        let epoch = privacyEpoch, id = ObjectIdentifier(window)
        ownedModals[id] = window
        defer { ownedModals[id] = nil }
        let response = operation()
        return permitsPresentation(epoch) ? response : .cancel
    }
    func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse { runModal(alert.window) { alert.runModal() } }
    private func cancelOwnedModals() {
        for window in Array(ownedModals.values) {
            if let panel = window as? NSSavePanel { panel.cancel(nil) }
            if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
            if NSApp.modalWindow === window { NSApp.abortModal() }
            window.orderOut(nil)
            window.title = L(.contentHidden); window.representedURL = nil
            window.contentView?.isHidden = true
            window.contentView?.setAccessibilityHidden(true)
        }
    }
    @Published var revealed = false
    @Published var canReceiveInput = false
    @Published var canOpenIntakeSettings = false
    @Published var inputFeedback = ""
    @Published var dropCount = 0
    /// The input strip and mouse gate share one layout, without retaining a
    /// transient coordinate from the reveal animation.
    func inputRegion(width: CGFloat) -> CGRect { revealed ? LineInputLayout.region(width: width) : .zero }
    var onPasteInput: () -> Void = {}
    private var openSettingsAction: () -> Void = {}
    private var newNoteAction: () -> Void = {}
    var onOpenIntakeSettings: () -> Void {
        get { { [weak self] in self?.dismissEntryHint(); self?.openSettingsAction() } }
        set { openSettingsAction = newValue }
    }
    var onNewNote: () -> Void {
        get { { [weak self] in self?.dismissEntryHint(); self?.newNoteAction() } }
        set { newNoteAction = newValue }
    }
    @Published private(set) var entryHintDismissed: Bool
    private let hintDefaults: UserDefaults
    var showsEntryHint: Bool {
        !entryHintDismissed && revealed && canOpenIntakeSettings && !snapshot.privacyHidden && dropCount == 0 && inputFeedback.isEmpty
    }
    func dismissEntryHint() {
        guard !snapshot.privacyHidden, !entryHintDismissed else { return }
        entryHintDismissed = true
        hintDefaults.set(true, forKey: "redRopeEntryHintDismissed")
    }
    var onOpenNote: (UUID) -> Void = { _ in }
    var onRopeMenuProvider: (() -> NSMenu)?
    var onReceiveInput: ([ImportRequest]) -> Bool = { _ in false }
    var hitRects: [UUID: CGRect] = [:]
    // Screen width limits the viewport, never the number of hanging materials.
    var maxItems = Int.max { didSet { if oldValue != maxItems { Task { await render(snapshot) } } } }
    @Published private(set) var viewportWidth: CGFloat = 0
    @Published private(set) var scrollOffset: CGFloat = 0
    var onPrepareDrag: (Pegged) async throws -> NSFilePromiseProvider = { _ in throw StoreError.invalidSource }
    var contentWidth: CGFloat { contentWidth(for: viewportWidth) }
    private func contentWidth(for width: CGFloat) -> CGFloat {
        let span = CGFloat(max(0, items.count - 1)) * Layout.spacing
        // Keep the established centred layout while every card fits on screen.
        return span + Layout.cardWidth <= width ? width : span + Layout.cardWidth + 80
    }
    var maximumScrollOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    func resizeViewport(_ width: CGFloat) {
        viewportWidth = max(0, width)
        scrollOffset = min(scrollOffset, maximumScrollOffset)
    }
    func scroll(by delta: CGFloat) {
        guard revealed, !snapshot.privacyHidden, draggingID == nil, pressedID == nil, delta.isFinite else { return }
        scrollOffset = min(maximumScrollOffset, max(0, scrollOffset + delta))
    }
    func scrollPage(forward: Bool) { scroll(by: (forward ? 1 : -1) * max(Layout.spacing, viewportWidth * 0.75)) }
    func cardX(index: Int, width: CGFloat) -> CGFloat {
        let extent = contentWidth(for: width)
        return Layout.x(index: index, count: items.count, width: extent) - min(scrollOffset, max(0, extent - width))
    }
    func scrollRegion(width: CGFloat) -> CGRect {
        guard revealed, !snapshot.privacyHidden, contentWidth > width else { return .zero }
        return CGRect(x: 0, y: Layout.ropeTop + 20, width: width, height: Layout.panelHeight - Layout.ropeTop - 20)
    }
    func pageControlsRegion(width: CGFloat) -> CGRect {
        guard revealed, !snapshot.privacyHidden, maximumScrollOffset > 0 else { return .zero }
        return CGRect(x: width / 2 - 65, y: Layout.panelHeight - 30, width: 130, height: 30)
    }
    func acceptsClick(at point: CGPoint, width: CGFloat) -> Bool {
        guard revealed, CGRect(x: 0, y: 0, width: width, height: Layout.panelHeight).contains(point) else { return false }
        // The rope settings menu remains available while previews are private.
        if inputRegion(width: width).contains(point) { return true }
        guard !snapshot.privacyHidden else { return false }
        return hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(point) }
            || pageControlsRegion(width: width).contains(point)
    }
    func selectForKeyboard(step: Int) {
        guard revealed, !snapshot.privacyHidden, !items.isEmpty, pressedID == nil, draggingID == nil else { return }
        let current = keyboardID.flatMap { id in items.firstIndex { $0.id == id } }
        let index = min(items.count - 1, max(0, (current ?? 0) + (current == nil ? 0 : step)))
        keyboardID = items[index].id
        let x = cardX(index: index, width: viewportWidth)
        if x - Layout.cardWidth / 2 < 0 { scroll(by: x - Layout.cardWidth / 2 - 20) }
        if x + Layout.cardWidth / 2 > viewportWidth { scroll(by: x + Layout.cardWidth / 2 + 20 - viewportWidth) }
    }
    func cardAccessibilityLabel(_ item: Pegged) -> String {
        let kind: MessageKey
        switch item.kind { case .image: kind = .inputImages; case .text: kind = .inputText; case .pdf: kind = .materialPDF; case .file: kind = .inputFiles }
        let title = String(item.displayTitle.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(60))
        let position = (items.firstIndex { $0.id == item.id } ?? 0) + 1
        return L(kind) + " · " + title + " · " + String(format: L(.shelfPosition), position, items.count)
    }
    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }
    var liveCount: Int { items.filter { !$0.falling }.count }
    var onCopy: (UUID) -> Void = { _ in }
    var onCopySource: (UUID) -> Void = { _ in }
    var onOpen: (UUID) -> Void = { _ in }
    var onMarkup: (UUID) -> Void = { _ in }
    var onReveal: (UUID) -> Void = { _ in }
    var onCommand: (MaterialCommand) -> Void = { _ in }
    var onFall: ((Pegged) -> Void)?
    var onError: (Error) -> Void = { _ in }
    private var renderGeneration = 0
    private struct PresentationKey: Hashable {
        let materialID: UUID
        let versionID: UUID
        let digest: String
    }
    private struct Presentation {
        let thumb: NSImage
        let text: String?
    }
    // Retain only this shelf's current versions. Cache hits never bypass the
    // store's full payload digest check, and privacy drops all presentation data.
    private var presentations: [PresentationKey: Presentation] = [:]
    private var arrivedIDs = Set<UUID>()
    private var arrivalScrollOffset: CGFloat = 0
    func claimArrival(_ id: UUID) -> Bool {
        // Offscreen cards have already joined the shelf. Manually revealing one
        // should not make it fly in; genuinely added cards use the render anchor.
        arrivedIDs.insert(id).inserted && scrollOffset == arrivalScrollOffset
    }

    // Small shelves keep every native view stable. Above this measured threshold
    // retain the viewport plus two neighbours on each side, not all offscreen UI.
    static let normalShelfViewLimit = 32
    func presentedIndices(width: CGFloat) -> [Int] {
        guard items.count > Self.normalShelfViewLimit, width > 0 else { return Array(items.indices) }
        let firstX = cardX(index: 0, width: width)
        let padding = Layout.cardWidth / 2 + 2 * Layout.spacing
        let lower = max(0, min(items.count, Int(floor((-padding - firstX) / Layout.spacing))))
        let upper = max(lower, min(items.count, Int(ceil((width + padding - firstX) / Layout.spacing)) + 1))
        var indices = Array(lower..<upper)
        // Resize or an incoming record must not destroy a native drag/press host.
        for id in [draggingID, pressedID].compactMap({ $0 }) {
            if let index = items.firstIndex(where: { $0.id == id }), !indices.contains(index) { indices.append(index) }
        }
        return indices.sorted()
    }

    private let thumbnail: (URL) -> NSImage?
    init(store: MaterialStore, hintDefaults: UserDefaults = .standard, thumbnail: @escaping (URL) -> NSImage? = { makeThumbnail($0) }) {
        self.store = store; self.thumbnail = thumbnail
        self.hintDefaults = hintDefaults; entryHintDismissed = hintDefaults.bool(forKey: "redRopeEntryHintDismissed")
        scheduleGust()
    }
    func load() async throws {
        let loaded = try await store.load()
        if privacyOverride == nil && loaded.privacyHidden { privacyOverride = true }
        await render(loaded)
    }
    func render(_ next: WorkspaceSnapshot, flightID: UUID? = nil) async {
        var next = next
        if let privacyOverride { next.privacyHidden = privacyOverride }
        if next.privacyHidden {
            if !snapshot.privacyHidden { savedKeyboardID = keyboardID; savedScrollOffset = scrollOffset }
            // The cover owns the transition and invalidates every earlier operation.
            if !snapshot.privacyHidden { privacyEpoch += 1 }
            snapshot = next
            coverImmediately()
            return
        }
        let wasHidden = snapshot.privacyHidden
        renderGeneration += 1
        let token = renderGeneration
        snapshot = next
        let records = ShelfPolicy.visible(snapshot: next, matterID: next.selectedMatterID, capacity: maxItems)
        let payloads = await store.presentationPayloads(for: records)
        guard token == renderGeneration else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var cards = [Pegged]()
        var nextPresentations: [PresentationKey: Presentation] = [:]
        for record in records {
            do {
                guard let result = payloads[record.id] else { throw StoreError.notFound }
                let url = try result.get()
                guard token == renderGeneration else { return }
                guard let version = record.activeVersion else { throw StoreError.invalidSnapshot }
                let key = PresentationKey(materialID: record.id, versionID: version.id, digest: version.sha256)
                let presentation: Presentation
                if let cached = presentations[key] { presentation = cached }
                else {
                    let thumb = thumbnail(url) ?? (NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 80, height: 80)))
                    presentation = Presentation(thumb: thumb, text: textPreview(kind: record.kind, url: url))
                }
                nextPresentations[key] = presentation
                if var previous = previousByID[record.id], previous.versionID == record.activeVersionID, previous.url == url {
                    previous.thumb = presentation.thumb
                    previous.displayTitle = record.title
                    previous.kind = record.kind
                    previous.previewText = presentation.text
                    cards.append(previous)
                } else {
                    var card = Pegged(id: record.id, versionID: record.activeVersionID, url: url, thumb: presentation.thumb, flying: record.id == flightID)
                    card.displayTitle = record.title
                    card.kind = record.kind
                    card.previewText = presentation.text
                    cards.append(card)
                }
            } catch {
                // A damaged managed version remains in history; never prune the record.
                onError(error)
            }
        }
        guard token == renderGeneration else { return }
        let added = cards.last(where: { previousByID[$0.id] == nil })?.id
        presentations = nextPresentations
        arrivedIDs.formIntersection(cards.map(\.id))
        items = cards
        if let id = keyboardID, !cards.contains(where: { $0.id == id }) { keyboardID = nil }
        scrollOffset = min(scrollOffset, maximumScrollOffset)
        if viewportWidth > 0, let target = flightID ?? added, let index = cards.firstIndex(where: { $0.id == target }) {
            let center = Layout.x(index: index, count: cards.count, width: contentWidth)
            if center - Layout.cardWidth / 2 < scrollOffset { scrollOffset = max(0, center - Layout.cardWidth / 2 - 40) }
            if center + Layout.cardWidth / 2 > scrollOffset + viewportWidth { scrollOffset = min(maximumScrollOffset, center + Layout.cardWidth / 2 + 40 - viewportWidth) }
        }
        if wasHidden {
            keyboardID = savedKeyboardID.flatMap { id in cards.contains(where: { $0.id == id }) ? id : nil }
            scrollOffset = min(savedScrollOffset, maximumScrollOffset)
            inputFeedback = ""
        }
        arrivalScrollOffset = scrollOffset
    }
    func land(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].flying = false
    }
    func beginFlight(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].flying = true
    }
    func animateTakeDown(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        onFall?(items[index]); items[index].falling = true
        hitRects[id] = nil
    }
    func drop(_ id: UUID, quietly: Bool = false) { onCommand(.takeDown(id)) }
    func discard(_ id: UUID) { drop(id) }
    func clear() { onCommand(.takeDownUnpinned(snapshot.selectedMatterID)) }
    func copy(_ id: UUID) { onCopy(id) }
    func open(_ id: UUID) { onOpen(id) }
    func markup(_ id: UUID) { onMarkup(id) }
    func reveal(_ id: UUID) { onReveal(id) }
    func trash(_ id: UUID) { onCommand(.trash(id)) }
    func prune() {} // Losing an external source never removes managed records.
    func reloadThumbnail(for url: URL) { Task { await render(snapshot) } }
    private func textPreview(kind: MaterialKind, url: URL) -> String? {
        guard kind == .text, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4096) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    if url.pathExtension.lowercased() == "pdf" {
        // First page only; cap bitmap allocation independently of the caller's
        // requested detail size. Version/digest caching remains owned by Line.
        guard maxPixels > 0, let document = CGPDFDocument(url as CFURL), !document.isEncrypted,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard [box.origin.x, box.origin.y, box.width, box.height].allSatisfy({ $0.isFinite }),
              box.width >= 1, box.height >= 1, box.width <= 14_400, box.height <= 14_400,
              abs(box.origin.x) <= 14_400, abs(box.origin.y) <= 14_400 else { return nil }
        let rotated = abs(page.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(min(480, maxPixels)) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
    guard (try? ImageAdmission.validate(contentsOf: url)) != nil,
          let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A full-size neutral replacement for owned windows whose content must leave AX.
@MainActor func privacyPlaceholder(in window: NSWindow) -> NSView {
    let cover = PanelSurface(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 500, height: 300))
    let label = NSTextField(labelWithString: L(.contentHidden)); PanelAppearance.secondary(label); label.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(label)
    NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: cover.centerXAnchor), label.centerYAnchor.constraint(equalTo: cover.centerYAnchor)])
    return cover
}
