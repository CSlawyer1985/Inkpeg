import Foundation

public struct CaptureCandidate: Equatable, Sendable {
    public let url: URL
    public let byteCount: Int64
    public let modificationDate: Date
    public let decodable: Bool
    public let systemScreenshotMarked: Bool
    public init(url: URL, byteCount: Int64, modificationDate: Date, decodable: Bool, systemScreenshotMarked: Bool = false) {
        self.url = url; self.byteCount = byteCount; self.modificationDate = modificationDate
        self.decodable = decodable; self.systemScreenshotMarked = systemScreenshotMarked
    }
}
public enum CaptureDecision: Equatable, Sendable { case wait, ready(URL), ignore, failed }
public struct CaptureIntake: Sendable {
    private struct Entry: Sendable {
        var candidate: CaptureCandidate
        var firstSeen: Date
        var stableSince: Date
        var delivered = false
        var failed = false
    }
    private var history: Set<URL>
    private let onlyTagged: Bool
    private var entries = [URL: Entry]()
    public init(history: Set<URL> = [], onlyTagged: Bool = false) {
        self.history = Set(history.map(\.standardizedFileURL)); self.onlyTagged = onlyTagged
    }
    public mutating func observe(_ candidate: CaptureCandidate, now: Date) -> CaptureDecision {
        let url = candidate.url.standardizedFileURL
        guard url.isFileURL, candidate.byteCount >= 0,
              !history.contains(url), !onlyTagged || candidate.systemScreenshotMarked else { return .ignore }
        guard var entry = entries[url] else {
            entries[url] = Entry(candidate: candidate, firstSeen: now, stableSince: now)
            return .wait
        }
        if entry.delivered { return .ignore }
        if entry.candidate != candidate {
            if entry.failed { entry.firstSeen = now }
            entry.candidate = candidate
            entry.stableSince = now
            entry.failed = false
        } else if entry.failed { return .ignore }
        if candidate.byteCount > 0 && candidate.decodable && now.timeIntervalSince(entry.stableSince) >= 0.2 {
            entry.delivered = true
            entries[url] = entry
            return .ready(url)
        }
        if now.timeIntervalSince(entry.firstSeen) >= 5 {
            entry.failed = true
            entries[url] = entry
            return .failed
        }
        entries[url] = entry
        return .wait
    }
    // Delivery is not acceptance: only a committed import acknowledges success.
    public mutating func acknowledge(_ url: URL, success: Bool) {
        let key = url.standardizedFileURL
        entries[key] = nil
        if success { history.insert(key) }
    }
    public mutating func forgetMissing(_ url: URL) { entries[url.standardizedFileURL] = nil }
    public var waitingURLs: [URL] { entries.filter { !$0.value.delivered && !$0.value.failed }.map(\.key) }
}
