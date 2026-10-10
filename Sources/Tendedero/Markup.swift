import AppKit
import InkpegCore
import UniformTypeIdentifiers

/// Receives only a disposable edit session, never a material or external source.
@MainActor
final class Markup: NSObject, NSSharingServiceDelegate {
    static let shared = Markup()
    private var editing: URL?
    private let resultBuffer = EditResultBuffer()
    private var session: EditSession?
    private var store: MaterialStore?
    private var editorActive = false
    private var loadingResults = 0
    private var saving = false
    private var failed = false
    private var activeService: NSSharingService?
    var isEditing: Bool { editing != nil }
    var hasPendingResult: Bool { resultBuffer.pending != nil }
    var canRetrySaving: Bool { isEditing && !editorActive && loadingResults == 0 && !saving && (hasPendingResult || failed) }
    private var completion: ((EditResult) -> Void)?
    private let launchEditor: ((URL) -> Void)?
    private let reportFailure: (() -> Void)?
    private let persistResult: (EditSession, MaterialStore, Data) async throws -> Void
    // Isolate the native UI and async I/O boundaries; production uses the
    // system editor, alert and store, while adapter tests use synthetic data.
    init(launchEditor: ((URL) -> Void)? = nil, reportFailure: (() -> Void)? = nil,
         persistResult: @escaping (EditSession, MaterialStore, Data) async throws -> Void = { try await $1.writeEditingResult($0, data: $2) }) {
        self.launchEditor = launchEditor; self.reportFailure = reportFailure; self.persistResult = persistResult
        super.init()
    }
    func edit(_ session: EditSession, store: MaterialStore, onResult: @escaping (EditResult) -> Void) {
        guard editing == nil else { onResult(.cancel); return }
        self.session = session; self.store = store
        editing = session.workingURL; completion = onResult
        openEditor()
    }
    private func openEditor() {
        guard let draft = editing, !editorActive, loadingResults == 0, !saving else { return }
        editorActive = true; failed = false
        if let launchEditor { launchEditor(draft); return }
        if let service = NSSharingService(named: NSSharingService.Name("com.apple.MarkupUI.Markup")), service.canPerform(withItems: [draft]) {
            activeService = service
            service.delegate = self; NSApp.activate(ignoringOtherApps: true); service.perform(withItems: [draft])
        } else {
            guard NSWorkspace.shared.open(draft) else { finish(.cancel); return }
            let alert = NSAlert()
            alert.messageText = L(.markupFallbackTitle); alert.informativeText = L(.markupFallbackMessage)
            alert.addButton(withTitle: L(.saveCopy)); alert.addButton(withTitle: L(.cancel))
            let response = alert.runModal()
            editorActive = false
            if response == .alertFirstButtonReturn { Task { await self.receive([draft]) } }
            else { finish(.cancel) }
        }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in
            guard self.activeService === sharingService else { return }
            await self.receive(items)
        }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        Task { @MainActor in
            guard self.activeService === sharingService else { return }
            self.activeService = nil; self.editorActive = false
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError { self.finish(.cancel) }
            else { self.failed = true; self.showSaveError() }
        }
    }
    func receive(_ items: [Any]) async {
        guard let target = editing, let sessionID = session?.id else { return }
        editorActive = false; activeService = nil
        guard let item = items.first else {
            if !saving && loadingResults == 0 && !hasPendingResult { finish(.cancel) }
            return
        }
        loadingResults += 1
        let data: Data
        do { data = try await returnedData(item) }
        catch {
            loadingResults -= 1
            guard session?.id == sessionID else { return }
            failed = true; showSaveError(); return
        }
        loadingResults -= 1
        guard editing == target, session?.id == sessionID else { return }
        do {
            try resultBuffer.enqueue(data)
            failed = false
            await retrySaving()
        } catch { failed = true; showSaveError() }
    }
    private func returnedData(_ item: Any) async throws -> Data {
        let data: Data
        switch item {
            case let url as URL:
                guard url.isFileURL else { throw StoreError.invalidEdit }
                data = try Data(contentsOf: url)
            case let image as NSImage:
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw StoreError.invalidEdit }
                data = png
            case let provider as NSItemProvider:
                guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { throw StoreError.invalidEdit }
                data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: StoreError.invalidEdit) }
                    }
                }
            default: throw StoreError.invalidEdit
        }
        guard data.count <= 256 * 1024 * 1024 else { throw StoreError.invalidEdit }
        return data
    }
    func retrySaving() async {
        guard let session, let store, !editorActive, loadingResults == 0, !saving else { return }
        if resultBuffer.pending == nil { if failed { openEditor() }; return }
        saving = true; failed = false
        defer { saving = false }
        do {
            while resultBuffer.pending != nil {
                try await resultBuffer.persist { try await persistResult(session, store, $0) }
                guard self.session?.id == session.id else { return }
            }
            guard loadingResults == 0, !failed, !editorActive else { return }
            finish(.save(session.workingURL))
        } catch { failed = true; showSaveError() } // Keep the exact returned result and callback for retry.
    }
    private func showSaveError() {
        if let reportFailure { reportFailure(); return }
        let alert = NSAlert(); alert.messageText = L(.markupSaveFailed); alert.informativeText = L(.markupSaveRetained)
        alert.addButton(withTitle: L(.retryMarkup)); alert.addButton(withTitle: L(.retryLater))
        if alert.runModal() == .alertFirstButtonReturn { Task { await retrySaving() } }
    }
    private func finish(_ result: EditResult) {
        let callback = completion
        editing = nil; completion = nil; session = nil; store = nil
        editorActive = false; failed = false; activeService = nil
        callback?(result)
    }
}
