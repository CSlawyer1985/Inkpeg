import AppKit
import InkpegCore
import UniformTypeIdentifiers
import ImageIO

/// Convert only frame zero, after admission. The separate file URL/promise
/// carries all original frames and metadata unchanged.
func firstFrameRepresentations(contentsOf url: URL) throws -> (png: Data, tiff: Data) {
    try ImageAdmission.validate(contentsOf: url)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageAdmissionError.invalidImage }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]),
          let tiff = bitmap.representation(using: .tiff, properties: [:]) else { throw ImageAdmissionError.invalidImage }
    return (png, tiff)
}

/// The promise owns its delegate through userInfo, including after drag end.
@MainActor
final class CopyOutProvider: NSObject, NSFilePromiseProviderDelegate {
    let store: MaterialStore
    let id: UUID
    let versionID: UUID
    let suffix: String
    let canExport: () -> Bool
    init(store: MaterialStore, id: UUID, versionID: UUID, suffix: String, canExport: @escaping () -> Bool) {
        self.store = store; self.id = id; self.versionID = versionID; self.suffix = suffix; self.canExport = canExport
    }
    func provider() -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: suffix)?.identifier ?? UTType.data.identifier, delegate: self)
        provider.userInfo = self
        return provider
    }
    /// Prepare a readable, independent copy before publishing its URL. Chat
    /// fields often accept file URLs or bytes but do not resolve file promises.
    func prepareProvider(exportRoot: URL) async throws -> NSFilePromiseProvider {
        guard canExport() else { throw StoreError.invalidSource }
        let snapshot = try await store.load()
        guard let record = snapshot.materials.first(where: { $0.id == id }), !snapshot.privacyHidden else { throw StoreError.invalidSource }
        let payload = try await store.payloadURL(of: id, versionID: versionID)
        guard canExport() else { throw StoreError.invalidSource }
        let name = ContentStore.suggestedExportFilename(for: record, fileExtension: payload.pathExtension)
        let destination = exportRoot.appendingPathComponent("Exports/" + UUID().uuidString).appendingPathComponent(name)
        let exported = try await store.exportCopy(of: id, versionID: versionID, to: destination)
        try Task.checkCancellation()
        guard canExport() else { throw StoreError.invalidSource }
        var representations: [NSPasteboard.PasteboardType: Any] = [
            SystemClipboardGateway.ownType: "1"
        ]
        switch record.kind {
        case .text:
            representations[.string] = try String(contentsOf: exported, encoding: .utf8)
        case .image:
            let converted = try firstFrameRepresentations(contentsOf: exported)
            representations[.png] = converted.png; representations[.tiff] = converted.tiff
            representations[.fileURL] = exported.absoluteString
        case .pdf, .file:
            representations[.fileURL] = exported.absoluteString
        }
        guard canExport() else { throw StoreError.invalidSource }
        let provider = ContentFilePromiseProvider(fileType: UTType(filenameExtension: payload.pathExtension)?.identifier ?? UTType.data.identifier, delegate: self)
        provider.suggestedFilename = name
        provider.representations = representations
        provider.canExport = canExport
        provider.userInfo = self
        return provider
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider as? ContentFilePromiseProvider)?.suggestedFilename ?? ("Inkpeg-" + id.uuidString.prefix(8) + "." + suffix)
    }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                guard canExport() else { throw StoreError.invalidSource }
                _ = try await store.exportCopy(of: id, versionID: versionID, to: url)
                guard canExport() else { throw StoreError.invalidSource }
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
}

/// One dragging item, with both native input content and Finder's promise.
@MainActor
final class ContentFilePromiseProvider: NSFilePromiseProvider {
    var suggestedFilename: String?
    var representations: [NSPasteboard.PasteboardType: Any] = [:]
    var canExport: () -> Bool = { false }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        guard canExport() else { return [] }
        let preferred: [NSPasteboard.PasteboardType] = [.string, .png, .tiff, .fileURL, SystemClipboardGateway.ownType]
        return preferred.filter { representations[$0] != nil } + super.writableTypes(for: pasteboard)
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        // NSFilePromiseProvider's lazy callback only services its own promise
        // types; publish supplemental values immediately while authorised.
        representations[type] != nil ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard canExport() else { return nil }
        return representations[type] ?? super.pasteboardPropertyList(forType: type)
    }
}
