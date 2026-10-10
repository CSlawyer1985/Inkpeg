import Foundation
import InkpegCore

/// Only a user-selected directory; never reads or changes screenshot settings.
@MainActor
final class ScreenshotWatcher {
    private let monitor = CaptureMonitor()
    func start(in folder: URL, onCandidate: @escaping (URL) -> Void, onFailed: @escaping (URL) -> Void, onInvalidated: @escaping () -> Void) throws {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true).resolvingSymlinksInPath()
        try monitor.start(in: folder, onlyTagged: folder.resolvingSymlinksInPath() == desktop, onReady: onCandidate, onFailed: onFailed, onInvalidated: onInvalidated)
    }
    func stop() { monitor.stop() }
    func acknowledge(_ url: URL, success: Bool) { monitor.acknowledge(url, success: success) }
    func retry(_ url: URL) { monitor.retry(url) }
}
