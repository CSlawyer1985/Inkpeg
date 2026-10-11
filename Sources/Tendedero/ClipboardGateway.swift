import AppKit
import ImageIO
import InkpegCore
import UniformTypeIdentifiers

@MainActor final class SystemClipboardGateway: ClipboardGateway {
    static let ownType = NSPasteboard.PasteboardType("local.inkpeg.owned-copy")
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    func readSnapshot() throws -> ClipboardContents {
        try readSnapshot(allowing: ClipboardPreference(enabled: true))
    }
    func readSnapshot(allowing preferences: ClipboardPreference) throws -> ClipboardContents {
        let revision = changeCount
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= ClipboardLimits.items else { throw StoreError.budgetExceeded }
        if !items.isEmpty, items.allSatisfy({ $0.types.contains(Self.ownType) }) {
            return ClipboardContents(revision: revision, isSelfProduced: true, requests: [])
        }
        var files = [ImportRequest](), images = [ImportRequest](), texts = [ImportRequest]()
        var bytes = 0
        let candidates = items.filter { !$0.types.contains(Self.ownType) }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
        let hasFiles = candidates.contains { $0.types.contains(.fileURL) }
        let hasImages = candidates.contains { item in imageTypes.contains { item.types.contains($0) } }
        // Decide the representation before reading data; disabled files/images
        // must not fall back to their auxiliary labels or previews.
        if (hasFiles && !preferences.files) || (!hasFiles && hasImages && !preferences.images) || (!hasFiles && !hasImages && !preferences.text) {
            return ClipboardContents(revision: revision, requests: [])
        }
        for item in candidates {
            if hasFiles && !item.types.contains(.fileURL) { continue }
            if !hasFiles && hasImages && !imageTypes.contains(where: { item.types.contains($0) }) { continue }
            if item.types.contains(.fileURL) {
                guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost" else { throw StoreError.invalidPath }
                let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.volumeIsLocal == true, values.isRegularFile == true, values.isSymbolicLink != true else { throw StoreError.invalidSource }
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ||
                    CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                        .flatMap(CGImageSourceGetType).flatMap({ UTType($0 as String) })?.conforms(to: .image) == true {
                    try ImageAdmission.validate(contentsOf: url)
                }
                files.append(.file(url, .clipboard))
                continue
            }
            if let type = imageTypes.first(where: { item.types.contains($0) }) {
                guard let data = item.data(forType: type), data.count <= ClipboardLimits.imageBytes else { throw StoreError.invalidSource }
                try ImageAdmission.validate(data)
                guard data.count <= ClipboardLimits.batchBytes - bytes else { throw StoreError.budgetExceeded }
                bytes += data.count
                images.append(.imageData(data, SourceRecord(origin: .clipboard)))
                continue
            }
            if let text = item.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let size = text.utf8.count
                guard size <= ClipboardLimits.textBytes, size <= ClipboardLimits.batchBytes - bytes else { throw StoreError.budgetExceeded }
                bytes += size
                texts.append(.text(text, SourceRecord(origin: .clipboard)))
            }
        }
        guard changeCount == revision else { throw StoreError.sourceChanged }
        return ClipboardContents(revision: revision, requests: !files.isEmpty ? files : !images.isEmpty ? images : texts)
    }
}
