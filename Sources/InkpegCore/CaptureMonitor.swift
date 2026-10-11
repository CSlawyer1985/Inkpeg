import Foundation
import ImageIO
import Darwin

private actor CaptureProbe {
    func inspect(_ url: URL, taggedOnly: Bool) -> CaptureCandidate? {
        guard let before = try? SystemFileOperations().inspect(url), before.isRegularFile,
              !before.isSymbolicLink, before.byteCount <= 256 * 1024 * 1024 else { return nil }
        let marked = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { getxattr($0, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) >= 0 } ?? false
        }
        if taggedOnly && !marked { return nil }
        var decoded = false
        if before.byteCount > 0, let data = try? Data(contentsOf: url), Int64(data.count) == before.byteCount,
           (try? ImageAdmission.validate(data)) != nil,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
        }
        guard let after = try? SystemFileOperations().inspect(url), after.isRegularFile, !after.isSymbolicLink else { return nil }
        if before != after {
            return CaptureCandidate(url: url, byteCount: after.byteCount, modificationDate: after.modificationDate, decodable: false, systemScreenshotMarked: marked)
        }
        return CaptureCandidate(url: url, byteCount: before.byteCount, modificationDate: before.modificationDate, decodable: decoded, systemScreenshotMarked: marked)
    }
}

/// Explicit folder intake. Historical paths are excluded before any decoding.
@MainActor
public final class CaptureMonitor {
    private let observer = DirectoryObservation()
    private let probe = CaptureProbe()
    private var intake = CaptureIntake()
    private var history = Set<URL>()
    private var generation = 0
    private var active = false
    private var taggedOnly = false
    private var retryWork: DispatchWorkItem?
    private var onReady: (URL) -> Void = { _ in }
    private var onFailed: (URL) -> Void = { _ in }
    private var onInvalidated: () -> Void = {}
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"]
    public init() {}
    public func start(in folder: URL, onlyTagged: Bool = false, onReady: @escaping (URL) -> Void, onFailed: @escaping (URL) -> Void = { _ in }, onInvalidated: @escaping () -> Void = {}) throws {
        stop()
        taggedOnly = onlyTagged; self.onReady = onReady; self.onFailed = onFailed; self.onInvalidated = onInvalidated
        active = true
        do {
            try observer.start(in: folder, onBaseline: { urls in
                self.history = Set(urls.map(\.standardizedFileURL))
                self.intake = CaptureIntake(history: self.history, onlyTagged: onlyTagged)
            }, onScan: { [weak self] in self?.inspect($0) }, onInvalidated: { [weak self] in
                guard let self else { return }; self.stop(); self.onInvalidated()
            })
        } catch { stop(); throw error }
    }
    public func stop() {
        generation += 1; active = false
        retryWork?.cancel(); retryWork = nil; observer.stop()
    }
    public func acknowledge(_ url: URL, success: Bool) {
        intake.acknowledge(url, success: success)
        if success { history.insert(url.standardizedFileURL) }
    }
    public func retry(_ url: URL) {
        guard active else { return }
        acknowledge(url, success: false); inspect([url])
    }
    private func inspect(_ urls: [URL]) {
        guard active else { return }
        let token = generation
        let candidates = Set(urls.map(\.standardizedFileURL)).filter { !history.contains($0) && Self.extensions.contains($0.pathExtension.lowercased()) }
        Task {
            for url in candidates {
                guard active, token == generation else { return }
                guard let candidate = await probe.inspect(url, taggedOnly: taggedOnly) else {
                    if !FileManager.default.fileExists(atPath: url.path) { intake.forgetMissing(url) }
                    continue
                }
                guard active, token == generation else { return }
                // Monotonic elapsed time, independent of wall-clock changes.
                switch intake.observe(candidate, now: Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)) {
                case .ready(let ready): onReady(ready)
                case .failed: onFailed(url)
                case .wait, .ignore: break
                }
            }
            scheduleRetry()
        }
    }
    private func scheduleRetry() {
        guard active, retryWork == nil, !intake.waitingURLs.isEmpty else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, token == self.generation else { return }
            self.retryWork = nil; self.inspect(self.intake.waitingURLs)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
