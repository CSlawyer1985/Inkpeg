import AppKit
import InkpegCore

@MainActor
final class CaptureFolderCoordinator {
    private let store: MaterialStore
    private let watcher = ScreenshotWatcher()
    private var scopedFolder: URL?
    private var setting: CaptureFolderSetting?
    private var queue = [URL]()
    private var pending = Set<URL>()
    private var draining = false
    private var generation = 0
    var capacity: () -> Int = { 8 }
    var onSnapshot: (WorkspaceSnapshot) async -> Void = { _ in }
    var onImported: (UUID, CGRect?, WorkspaceSnapshot) async -> Void = { _, _, _ in }
    private(set) var status: MessageKey = .capturePaused { didSet { onStatusChanged() } }
    var onStatusChanged: () -> Void = {}
    var hasWarning: Bool { ![MessageKey.capturePaused, .captureActive].contains(status) }
    var onError: (Error) -> Void = { _ in }
    var isEnabled: Bool { scopedFolder != nil }
    var pendingCount: Int { pending.count }
    var selectedPath: String? { setting?.lastKnownPath }
    init(store: MaterialStore) { self.store = store }
    func restore(_ snapshot: WorkspaceSnapshot) {
        setting = snapshot.captureFolder
        guard let setting, setting.enabled else { return }
        do { try start(setting) }
        catch {
            stop(); status = .captureUnavailable
            log.notice("Capture restore failed with code \((error as NSError).code, privacy: .public)")
            onError(error)
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L(.chooseCaptureFolder)
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                let values = try folder.resourceValues(forKeys: [.volumeIsLocalKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.volumeIsLocal == true, values.isDirectory == true, values.isSymbolicLink != true else { throw StoreError.invalidPath }
                let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let selected = CaptureFolderSetting(bookmark: bookmark, lastKnownPath: folder.path, enabled: true)
                let snapshot = try await store.apply(.setCaptureFolder(selected))
                stop(); setting = selected
                await onSnapshot(snapshot)
                try start(selected)
            } catch { onError(error) }
        }
    }
    func toggleEnabled() {
        guard var selected = setting else { chooseFolder(); return }
        selected.enabled = !isEnabled
        Task {
            do {
                let snapshot = try await store.apply(.setCaptureFolder(selected))
                stop(); setting = selected
                await onSnapshot(snapshot)
                if selected.enabled { try start(selected) }
            } catch { onError(error) }
        }
    }
    func retryPending() {
        for url in pending { watcher.retry(url) }
    }
    func stop() {
        generation += 1; watcher.stop(); queue.removeAll(); pending.removeAll()
        scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = nil
        status = .capturePaused
    }
    private func start(_ selected: CaptureFolderSetting) throws {
        var stale = false
        let folder = try URL(resolvingBookmarkData: selected.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw StoreError.invalidSource }
        let values = try folder.resourceValues(forKeys: [.volumeIsLocalKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.volumeIsLocal == true, values.isDirectory == true, values.isSymbolicLink != true else { throw StoreError.invalidPath }
        _ = folder.startAccessingSecurityScopedResource()
        scopedFolder = folder
        do {
            try watcher.start(in: folder, onCandidate: { [weak self] in self?.enqueue($0) }, onFailed: { [weak self] url in
                self?.pending.insert(url); self?.status = .captureIncomplete
            }, onInvalidated: { [weak self] in self?.stop(); self?.status = .captureUnavailable })
            status = .captureActive
        } catch { stop(); status = .captureUnavailable; throw error }
    }
    private func enqueue(_ url: URL) {
        guard !queue.contains(url) else { return }
        queue.append(url)
        guard !draining else { return }
        draining = true
        Task {
            defer { draining = false }
            while !queue.isEmpty {
                let url = queue.removeFirst(), token = generation
                let area = captureRect(of: url) // Original metadata is read before the safe copy.
                do {
                    let current = try await store.load()
                    guard token == generation else { continue }
                    let result = try await store.importMaterial(.file(url, .screenshot), into: current.selectedMatterID, visibleCapacity: capacity())
                    guard token == generation else { continue }
                    switch result.disposition {
                    case .hanging(let id):
                        acknowledgeImport(url)
                        await onImported(id, area, result.snapshot)
                    case .duplicate:
                        acknowledgeImport(url)
                    case .shelfFull: pending.insert(url); status = .captureFull
                    }
                } catch { if token == generation { pending.insert(url); status = error as? StoreError == .budgetExceeded ? .captureStorageLimit : .captureImportFailed } }
            }
        }
    }
    private func acknowledgeImport(_ url: URL) {
        watcher.acknowledge(url, success: true)
        pending.remove(url)
        if pending.isEmpty { status = .captureActive }
    }
}
