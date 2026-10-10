import Foundation
import Darwin

/// Directory events only; no decoding, imports, recursion or system settings.
@MainActor
public final class DirectoryObservation {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var folder: URL?
    private var generation = 0
    private var onScan: ([URL]) -> Void = { _ in }
    private var onInvalidated: () -> Void = {}
    public init() {}
    public func start(in folder: URL, onBaseline: ([URL]) -> Void, afterBaseline: () throws -> Void = {}, onScan: @escaping ([URL]) -> Void, onInvalidated: @escaping () -> Void) throws {
        stop()
        guard folder.isFileURL else { throw StoreError.invalidPath }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.invalidPath }
        self.folder = folder; self.onScan = onScan; self.onInvalidated = onInvalidated
        onBaseline(try listing())
        try afterBaseline()
        let descriptor = open(folder.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.invalidSource }
        let token = generation
        let event = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        event.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.generation, let source = self.source else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.stop(); self.onInvalidated()
                } else { self.scheduleScan() }
            }
        }
        event.setCancelHandler { close(descriptor) }
        source = event
        event.resume()
        do { onScan(try listing()) } // Reconcile arrivals in the baseline/registration gap.
        catch { stop(); throw error }
    }
    public func stop() {
        generation += 1
        pending?.cancel(); pending = nil
        source?.cancel(); source = nil
    }
    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { self.onScan(try self.listing()) }
            catch { self.stop(); self.onInvalidated() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    private func listing() throws -> [URL] {
        guard let folder else { throw StoreError.invalidSource }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
}
