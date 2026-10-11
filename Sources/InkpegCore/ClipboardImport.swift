import Foundation

public struct ClipboardContents: Sendable {
    public let revision: Int
    public let isSelfProduced: Bool
    public let requests: [ImportRequest]
    public init(revision: Int, isSelfProduced: Bool = false, requests: [ImportRequest]) {
        self.revision = revision; self.isSelfProduced = isSelfProduced; self.requests = requests
    }
}
@MainActor public protocol ClipboardGateway {
    var changeCount: Int { get }
    func readSnapshot() throws -> ClipboardContents
    func readSnapshot(allowing preferences: ClipboardPreference) throws -> ClipboardContents
}
public extension ClipboardGateway {
    func readSnapshot(allowing preferences: ClipboardPreference) throws -> ClipboardContents {
        let value = try readSnapshot()
        return ClipboardContents(revision: value.revision, isSelfProduced: value.isSelfProduced, requests: value.requests.filter { preferences.accepts($0) })
    }
}
public enum ClipboardIntakeState: Sendable { case active, paused, hidden, pending, changedFile, unavailable, rejected }
public enum ClipboardLimits {
    public static let items = 32
    public static let textBytes = 1024 * 1024
    public static let imageBytes = 16 * 1024 * 1024
    public static let batchBytes = 64 * 1024 * 1024
    public static let fileBytes = 64 * 1024 * 1024
    public static let imagePixels = 32 * 1024 * 1024
}

@MainActor public final class ClipboardImportService {
    public private(set) var isEnabled = true
    public private(set) var preferences = ClipboardPreference()
    public private(set) var isSavingPreferences = false { didSet { onStateChanged() } }
    public private(set) var state = ClipboardIntakeState.paused { didSet { onStateChanged() } }
    public var pendingCount: Int { pending.count }
    public var hasUnsavedInput: Bool { busy || !pending.isEmpty }
    public var canDiscardPending: Bool { !busy && !pending.isEmpty }
    public var onSnapshot: (WorkspaceSnapshot) async -> Void = { _ in }
    public var onImported: (UUID, WorkspaceSnapshot) async -> Void = { _, _ in }
    public var onStateChanged: () -> Void = {}
    private let gateway: any ClipboardGateway
    private let store: MaterialStore
    private let capacity: () -> Int
    private let canRead: () -> Bool
    private var running = false
    private var busy = false { didSet { onStateChanged() } }
    private var preferenceUnavailable = false
    private var lastRevision: Int?
    private var preferenceToken = UUID()
    private struct PendingInput {
        let request: ImportRequest
        let matterID: UUID
        let fingerprint: ClipboardFileFingerprint?
    }
    private var pending: [PendingInput] = []
    private var pendingRevision: Int?
    private var pendingManual = false
    public var canReceiveManual: Bool { running && !busy && !isSavingPreferences && pending.isEmpty && canRead() }
    public init(gateway: any ClipboardGateway, store: MaterialStore, capacity: @escaping () -> Int = { 8 }, canRead: @escaping () -> Bool = { true }) {
        self.gateway = gateway; self.store = store; self.capacity = capacity; self.canRead = canRead
    }
    public func start() async {
        guard !running else { return }
        running = true
        let baseline = gateway.changeCount
        do { preferences = try await store.clipboardPreferences(); isEnabled = preferences.enabled }
        catch { isEnabled = false; preferenceUnavailable = true; state = .unavailable; return }
        guard running else { return }
        preferenceUnavailable = false
        lastRevision = preferences.includeExisting ? nil : baseline
        await poll()
    }
    public func poll() async {
        guard running, !busy, !isSavingPreferences else { return }
        guard pending.isEmpty else { if state != .changedFile { state = .pending }; return }
        guard !preferenceUnavailable else { state = .unavailable; return }
        guard isEnabled else { state = .paused; return }
        guard canRead() else { state = .hidden; return }
        let entryRevision = lastRevision, entryPreferenceToken = preferenceToken
        busy = true; defer { busy = false }
        do {
            let workspace = try await store.load()
            guard running, isEnabled, canRead(), !workspace.privacyHidden else { state = isEnabled ? .hidden : .paused; return }
            let revision = gateway.changeCount
            guard revision != lastRevision else { if state == .hidden { state = .active }; return }
            let contents: ClipboardContents
            do { contents = try gateway.readSnapshot(allowing: preferences) }
            catch { lastRevision = revision; state = .rejected; return }
            guard contents.revision == revision, gateway.changeCount == revision else { return }
            guard running, isEnabled, canRead() else { return }
            lastRevision = revision
            guard !contents.isSelfProduced else { state = .active; return }
            try await prepare(contents.requests, workspace: workspace, manual: false, revision: revision)
            await drain()
        } catch {
            if error as? StoreError == .operationInProgress {
                if preferenceToken == entryPreferenceToken {
                    state = .unavailable
                    lastRevision = entryRevision
                }
            }
            else { state = .rejected }
        }
    }
    public func setEnabled(_ enabled: Bool) async {
        var value = preferences; value.enabled = enabled
        await updatePreferences(value)
    }
    @discardableResult public func updatePreferences(_ value: ClipboardPreference) async -> Bool {
        guard !isSavingPreferences else { return false }
        preferenceToken = UUID()
        isSavingPreferences = true
        let baseline = gateway.changeCount
        isEnabled = false
        do {
            try await store.setClipboardPreferences(value)
            preferences = value; preferenceUnavailable = false; isEnabled = value.enabled
            state = value.enabled ? .active : .paused
            lastRevision = value.includeExisting ? nil : baseline
            isSavingPreferences = false
            if value.enabled { await poll() }
            return true
        } catch {
            preferenceUnavailable = true; state = .unavailable; isSavingPreferences = false
            return false
        }
    }
    public func pasteCurrent() async {
        guard canReceiveManual else { return }
        busy = true; defer { busy = false }
        do {
            let workspace = try await store.load()
            guard running, canRead(), !workspace.privacyHidden else { state = .hidden; return }
            let revision = gateway.changeCount, contents = try gateway.readSnapshot()
            guard contents.revision == revision, gateway.changeCount == revision else { return }
            guard !contents.isSelfProduced else { return }
            try await prepare(contents.requests, workspace: workspace, manual: true, revision: revision)
            await drain()
        } catch { state = .rejected }
    }
    public func receive(_ requests: [ImportRequest]) async {
        guard canReceiveManual else { return }
        busy = true
        await receiveReserved(requests)
    }
    /// Reserve intake synchronously before AppKit acknowledges a drop.
    @discardableResult public func enqueueManual(_ requests: [ImportRequest]) -> Bool {
        guard canReceiveManual, !requests.isEmpty, requests.count <= ClipboardLimits.items else { return false }
        busy = true
        Task { await receiveReserved(requests) }
        return true
    }
    private func receiveReserved(_ requests: [ImportRequest]) async {
        defer { busy = false }
        do {
            let workspace = try await store.load()
            guard running, canRead(), !workspace.privacyHidden else { state = .hidden; return }
            try await prepare(requests, workspace: workspace, manual: true, revision: nil)
            await drain()
        } catch { state = .rejected }
    }
    private func prepare(_ requests: [ImportRequest], workspace: WorkspaceSnapshot, manual: Bool, revision: Int?) async throws {
        guard requests.count <= ClipboardLimits.items else { throw StoreError.budgetExceeded }
        var bytes = 0, prepared: [PendingInput] = []
        for request in requests {
            var fingerprint: ClipboardFileFingerprint?
            let size: Int
            switch request {
            case .text(let text, _):
                size = text.utf8.count
                guard size <= ClipboardLimits.textBytes else { throw StoreError.budgetExceeded }
            case .imageData(let data, _):
                size = data.count
                guard size <= ClipboardLimits.imageBytes else { throw StoreError.budgetExceeded }
            case .file(let url, _):
                let value = try await store.clipboardFileFingerprint(url)
                guard value.info.byteCount <= Int64(ClipboardLimits.batchBytes) else { throw StoreError.budgetExceeded }
                size = Int(value.info.byteCount); fingerprint = value
            }
            guard size <= ClipboardLimits.batchBytes - bytes else { throw StoreError.budgetExceeded }
            bytes += size
            prepared.append(PendingInput(request: request, matterID: workspace.selectedMatterID, fingerprint: fingerprint))
        }
        guard running, canRead(), manual || isEnabled else { throw StoreError.operationInProgress }
        pending = prepared; pendingRevision = revision; pendingManual = manual
    }
    public func retryPending() async {
        guard running, canRead(), !busy else { return }
        if pending.isEmpty {
            if isEnabled { lastRevision = nil; await poll() }
            else { await pasteCurrent() }
            return
        }
        guard pendingManual || isEnabled else { return }
        busy = true
        await drain()
        busy = false
        if pending.isEmpty, isEnabled { await poll() }
    }
    public func stop() { running = false }
    /// Called only after the UI confirms abandoning inputs that are not saved.
    @discardableResult public func discardPending() -> Bool {
        guard !busy else { return false }
        lastRevision = pendingRevision ?? lastRevision
        pending.removeAll()
        pendingRevision = nil; pendingManual = false
        state = isEnabled ? .active : .paused
        return true
    }
    private func drain() async {
        while let item = pending.first {
            guard running, pendingManual || isEnabled else { state = .paused; return }
            guard canRead() else { state = .hidden; return }
            do {
                let workspace = try await store.load()
                guard running, pendingManual || isEnabled, canRead(), !workspace.privacyHidden else { state = isEnabled ? .hidden : .paused; return }
                let result = try await store.importMaterial(item.request, into: item.matterID, visibleCapacity: capacity(), deduplicateClipboardContent: true, expectedClipboardFile: item.fingerprint, duplicatePolicy: pendingManual ? .rehangTakenDown : .keepExisting)
                guard result.disposition != .shelfFull else { state = .pending; return }
                pending.removeFirst()
                await onSnapshot(result.snapshot)
                if case .hanging(let id) = result.disposition, running, pendingManual || isEnabled, canRead() { await onImported(id, result.snapshot) }
            } catch { state = item.fingerprint != nil && ![StoreError.operationInProgress, .budgetExceeded, .unavailableSpace].contains(error as? StoreError) ? .changedFile : .pending; return }
        }
        pendingRevision = nil; pendingManual = false
        state = !isEnabled ? .paused : canRead() ? .active : .hidden
    }
}
