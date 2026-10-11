import AppKit
import InkpegCore

@MainActor
final class MaterialActions {
    private let line: Line
    private let root: URL
    private let pasteboard: NSPasteboard
    private let write: (NSPasteboard, NSPasteboardItem) -> Bool
    var onError: (Error) -> Void = { _ in }
    init(line: Line, root: URL, pasteboard: NSPasteboard = .general, write: @escaping (NSPasteboard, NSPasteboardItem) -> Bool = { board, item in
        board.clearContents(); return board.writeObjects([item])
    }) { self.line = line; self.root = root; self.pasteboard = pasteboard; self.write = write }
    static func copyLabel(for kind: MaterialKind) -> MessageKey { kind == .text ? .copyWithSource : .copy }
    func dragProvider(_ item: Pegged) async throws -> NSFilePromiseProvider {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        let adapter = CopyOutProvider(store: line.store, id: item.id, versionID: item.versionID, suffix: item.url.pathExtension) { [weak line] in line?.permitsPresentation(epoch) == true }
        return try await adapter.prepareProvider(exportRoot: root)
    }
    func copy(_ id: UUID, includeSource: Bool = false) async throws {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch), let record = line.snapshot.materials.first(where: { $0.id == id }) else { throw StoreError.invalidSource }
        let url = try await line.store.payloadURL(of: id, versionID: record.activeVersionID)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        let board = pasteboard, item = NSPasteboardItem()
        switch record.kind {
        case .image:
            let converted = try firstFrameRepresentations(contentsOf: url)
            item.setData(converted.png, forType: .png)
        case .text:
            var text = try String(contentsOf: url, encoding: .utf8)
            if includeSource {
                let source = SourceFormatter.describe(record.source, localizer: appLocalizer) ?? L(.sourceMissing)
                text += "\n\n" + L(.sourceLabel) + " " + source
            }
            item.setString(text, forType: .string)
        case .pdf, .file:
            let export = try await export(record, versionID: record.activeVersionID, suffix: url.pathExtension)
            guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
            item.setString(export.absoluteString, forType: .fileURL)
        }
        item.setString("1", forType: SystemClipboardGateway.ownType)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        guard write(board, item) else { throw StoreError.unavailableSpace }
        line.copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak line] in if line?.copiedID == id { line?.copiedID = nil } }
    }
    func open(_ id: UUID) async throws {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch), let record = line.snapshot.materials.first(where: { $0.id == id }) else { throw StoreError.invalidSource }
        let payload = try await line.store.payloadURL(of: id, versionID: record.activeVersionID)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        let url = try await export(record, versionID: record.activeVersionID, suffix: payload.pathExtension)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        if record.kind == .file { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if !NSWorkspace.shared.open(url) { throw StoreError.invalidSource }
    }
    func reveal(_ id: UUID) async throws {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch), let record = line.snapshot.materials.first(where: { $0.id == id }) else { throw StoreError.invalidSource }
        let payload = try await line.store.payloadURL(of: id, versionID: record.activeVersionID)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        let url = try await export(record, versionID: record.activeVersionID, suffix: payload.pathExtension)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func markup(_ id: UUID) async throws {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        if let record = line.snapshot.materials.first(where: { $0.id == id }), record.kind == .image {
            try ImageAdmission.validate(contentsOf: await line.store.payloadURL(of: id))
        }
        let session = try await line.store.createDerivedVersion(of: id, kind: .markup)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        Markup.shared.edit(session, store: self.line.store) { [weak self] result in
            guard let self else { return }
            Task {
                do { await self.line.render(try await self.line.store.finishEditing(session, result: result)) }
                catch { self.onError(error) }
            }
        }
    }
    private func export(_ record: MaterialRecord, versionID: UUID, suffix: String) async throws -> URL {
        let name = ContentStore.suggestedExportFilename(for: record, fileExtension: suffix)
        let destination = root.appendingPathComponent("Exports/" + UUID().uuidString).appendingPathComponent(name)
        return try await line.store.exportCopy(of: record.id, versionID: versionID, to: destination)
    }
}
