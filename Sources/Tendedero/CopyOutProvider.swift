import AppKit
import InkpegCore
import UniformTypeIdentifiers

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
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "Inkpeg-" + id.uuidString.prefix(8) + "." + suffix
    }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                guard canExport() else { throw StoreError.invalidSource }
                _ = try await store.exportCopy(of: id, versionID: versionID, to: url)
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
}
