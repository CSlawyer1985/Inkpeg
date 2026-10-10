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
        a.id == b.id && a.url == b.url && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
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
    @Published var revealed = false
    @Published var canReceiveInput = false
    @Published var canOpenIntakeSettings = false
    @Published var inputFeedback = ""
    @Published var dropCount = 0
    /// The input strip and mouse gate share one layout, without retaining a
    /// transient coordinate from the reveal animation.
    func inputRegion(width: CGFloat) -> CGRect { revealed ? LineInputLayout.region(width: width) : .zero }
    var onPasteInput: () -> Void = {}
    var onOpenIntakeSettings: () -> Void = {}
    var onNewNote: () -> Void = {}
    var onOpenNote: (UUID) -> Void = { _ in }
    var onRopeMenuProvider: (() -> NSMenu)?
    var onReceiveInput: ([ImportRequest]) -> Bool = { _ in false }
    var hitRects: [UUID: CGRect] = [:]
    var maxItems = 8 { didSet { if oldValue != maxItems { Task { await render(snapshot) } } } }
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

    init(store: MaterialStore) { self.store = store; scheduleGust() }
    func load() async throws { await render(try await store.load()) }
    func render(_ next: WorkspaceSnapshot, flightID: UUID? = nil) async {
        renderGeneration += 1
        let token = renderGeneration
        snapshot = next
        let records = ShelfPolicy.visible(snapshot: next, matterID: next.selectedMatterID, capacity: maxItems)
        var cards = [Pegged]()
        for record in records {
            do {
                let url = try await store.payloadURL(of: record.id, versionID: record.activeVersionID)
                guard token == renderGeneration else { return }
                let thumb = makeThumbnail(url) ?? (NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 80, height: 80)))
                if var previous = items.first(where: { $0.id == record.id && $0.url == url }) {
                    previous.thumb = thumb
                    previous.displayTitle = record.title
                    previous.kind = record.kind
                    previous.previewText = textPreview(kind: record.kind, url: url)
                    cards.append(previous)
                } else {
                    var card = Pegged(id: record.id, versionID: record.activeVersionID, url: url, thumb: thumb, flying: record.id == flightID)
                    card.displayTitle = record.title
                    card.kind = record.kind
                    card.previewText = textPreview(kind: record.kind, url: url)
                    cards.append(card)
                }
            } catch {
                // A damaged managed version remains in history; never prune the record.
                onError(error)
            }
        }
        guard token == renderGeneration else { return }
        items = cards
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
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
